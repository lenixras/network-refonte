#!/usr/bin/env bash
# =============================================================================
# proxmox-create-vms.sh — Cree les VM du plan d'architecture sur pve01/pve02
#                         a partir de inventory/inventory.yaml (clone du
#                         template cloud-init, dimensionnement strict du plan).
#
# PURPOSE (exemple publié — données anonymisées) :
#   Provisionner de façon reproductible les 12 VM du reference design
#   (VMID 101..501, cf. docs/00-architecture-reference.md §5) sans saisie
#   manuelle : l'inventaire YAML est la seule source de verite.
#
# PREREQUIS :
#   - Execute sur un poste avec acces SSH root vers pve01/pve02 (cles SSH)
#   - Proxmox VE 8.2 sur les deux noeuds ; cluster `pve` forme (corosync
#     10.10.15.10/11, VLAN 15)
#   - Template cloud-init de reference : VMID 9000 (convention locale, hors
#     plan) — disques SCSI, qemu-guest-agent installe, agent=1
#   - Pont VLAN-aware `vmbr0` uplink vers trunk Core (VLAN 20/50/60/80/90)
#   - Stockages declares : local-zfs (systeme) ; nas-nfs reserve au PBS
#   - yq (v4) OU python3 pour lire l'inventaire
#   - Secrets via .env : VM_ADMIN_PASSWORD (compte cloud-init) — JAMAIS en dur
#
# DONNÉES ANONYMISÉES : domaine example.local, IPs du plan interne uniquement.
#
# SECURITE : DRY-RUN PAR DEFAUT. Rien n'est cree sans --apply.
#
# USAGE :
#   ./proxmox-create-vms.sh                 # dry-run : affiche les commandes
#   ./proxmox-create-vms.sh --apply         # cree reellement les VM
#   ./proxmox-create-vms.sh --apply --only 101,102
#   INVENTORY=/chemin/inventory.yaml ./proxmox-create-vms.sh --apply
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-${SCRIPT_DIR}/../inventory/inventory.yaml}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"   # template cloud-init (convention locale)
BRIDGE="${BRIDGE:-vmbr0}"                # pont VLAN-aware uplink Core
STORAGE="${STORAGE:-local-zfs}"
SSH_USER="${PVE_SSH_USER:-root}"
APPLY=0
ONLY=""
PREFIX_DEFAULT="/24"                     # hors DMZ (see plan §3)

usage() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)     APPLY=1; shift ;;
    --dry-run)   APPLY=0; shift ;;
    --only)      ONLY="$2"; shift 2 ;;
    --template)  TEMPLATE_VMID="$2"; shift 2 ;;
    --inventory) INVENTORY="$2"; shift 2 ;;
    -h|--help)   usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

[[ -f "$INVENTORY" ]] || { echo "ERREUR : inventaire introuvable : $INVENTORY" >&2; exit 1; }

# --- Secrets : uniquement en mode apply -------------------------------------
if [[ "$APPLY" == "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/../.env" ]]; then
    set -a; . "${SCRIPT_DIR}/../.env"; set +a
    echo "INFO : secrets chargés depuis .env (non affichés)."
  fi
  if [[ -z "${VM_ADMIN_PASSWORD:-}" ]]; then
    echo "ERREUR : VM_ADMIN_PASSWORD absent (définir dans .env). Refus sans secret." >&2
    exit 2
  fi
fi

# -----------------------------------------------------------------------------
# Lecture de l'inventaire -> TSV :
# vmid name node cores mem disk_gb vlan ip gw dns prefix ostype
# (gw/prefix deduits du plan VLAN ; DMZ = /28 ; Windows ostype w9, Linux l26)
# -----------------------------------------------------------------------------
# (Passage par python3+PyYAML : lecture fiable du YAML ; yq v4 est utilise
#  par les autres scripts de l'atelier, cf. README.)
parse_inventory() {
  python3 - "$INVENTORY" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
vlans = {v["id"]: v for v in inv["vlans"]}
dns = ",".join(inv["network_defaults"]["dns_servers"])
for vm in inv["vms"]:
    v = vlans[vm["vlan"]]
    prefix = "/28" if v["name"] == "DMZ" else ("/22" if v["name"] in ("WIFI", "GUEST") else "/24")
    ostype = "w9" if "Windows" in vm["os"] else "l26"
    print("\t".join(map(str, [
        vm["vmid"], vm["name"], vm["node"], vm["cores"], vm["memory_mb"],
        vm["disk_gb"], vm["vlan"], vm["ip"], v["gw"], dns, prefix, ostype,
    ])))
PY
}

command -v python3 >/dev/null 2>&1 || { echo "ERREUR : python3 (avec PyYAML) requis." >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "ERREUR : binaire ssh requis." >&2; exit 2; }

ROWS="$(parse_inventory)"
[[ -n "$ROWS" ]] || { echo "ERREUR : aucune VM dans l'inventaire." >&2; exit 3; }

run() { # execute ou affiche selon APPLY ( recoit une commande en une seule cha )
  if [[ "$APPLY" == "1" ]]; then
    bash -c "$*"
  else
    echo "DRY-RUN | $*"
  fi
}

echo "==============================================================="
echo " Provisionnement Proxmox VE — $( [[ $APPLY == 1 ]] && echo 'MODE APPLY' || echo 'MODE DRY-RUN' )"
echo " Inventaire : $INVENTORY | template : ${TEMPLATE_VMID} | pont : ${BRIDGE}"
echo "==============================================================="

created=0; skipped=0; failed=0

while IFS=$'\t' read -r vmid name node cores mem disk vlan ip gw dns prefix ostype; do
  [[ -z "${vmid:-}" ]] && continue
  # filtre --only
  if [[ -n "$ONLY" && ",${ONLY}," != *",${vmid},"* ]]; then continue; fi

  fqdn="${name}.example.local"
  ssh_node="ssh -o BatchMode=yes ${SSH_USER}@${node}"

  # --- Garde-fou : la VM existe-t deja ? -----------------------------------
  if [[ "$APPLY" == "1" ]] && $ssh_node "qm status ${vmid}" >/dev/null 2>&1; then
    echo "SKIP : VMID ${vmid} (${name}) existe deja sur ${node}."
    skipped=$((skipped+1)); continue
  fi

  echo "-- VMID ${vmid} | ${name} (${ostype}) | ${node} | ${cores} vCPU / ${mem} Mo / ${disk} Go | VLAN ${vlan} | ${ip}${prefix}"

  # --- 1) Clone du template cloud-init (execute sur le nœud cible) ----------
  run "ssh ${SSH_USER}@${node} qm clone ${TEMPLATE_VMID} ${vmid} --name ${name} --storage ${STORAGE} --full"

  # --- 2) Dimensionnement + reseau cloud-init conformes au plan -------------
  run "ssh ${SSH_USER}@${node} qm set ${vmid} --cores ${cores} --memory ${mem} --balloon 0 --ostype ${ostype} --cpu host --agent enabled=1 --onboot 1 --net0 virtio,bridge=${BRIDGE},tag=${vlan},firewall=1 --ipconfig0 ip=${ip}${prefix},gw=${gw} --nameserver '${dns}' --searchdomain example.local --ciuser admininit --cipassword \"\${VM_ADMIN_PASSWORD}\""

  # --- 3) Disque systeme a la taille du plan (resize si necessaire) ---------
  run "ssh ${SSH_USER}@${node} qm resize ${vmid} scsi0 ${disk}G"

  # --- 3) PBS01 : montee NFS du NAS en datastore (plan : backup sur NAS) ---
  if [[ "$name" == "PBS01" ]]; then
    echo "NOTE : apres creation, monter nas-nfs (10.10.50.20) puis initialiser"
    echo "       le datastore PBS 'backup' avec retention 7j/4s/12m (cf. backup/pbs-backup-job.sh)"
  fi

  created=$((created+1))
done <<< "$ROWS"

echo "---------------------------------------------------------------"
echo "Resume : ${created} VM(s) preparees, ${skipped} ignoree(s), ${failed} echec(s)."
if [[ "$APPLY" == "0" ]]; then
  echo "DRY-RUN terminé. Relancer avec --apply pour creer les VM (VM_ADMIN_PASSWORD requis dans .env)."
fi
[[ "$failed" -eq 0 ]] || exit 4
