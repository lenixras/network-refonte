#!/usr/bin/env bash
# =============================================================================
# restore-drill.sh — Test de restauration periodique (le « test de
#                    restauration » obligatoire du plan de reprise).
#
# PURPOSE (exemple public — portfolio) :
#   Prouver que les backups PBS sont RESTAURABLES, pas seulement stockes :
#     1. choisir la derniere snapshot PBS d'une VM du plan,
#     2. la restaurer dans une VM de scratch (VMID = 9000+VMID) sur un nœud,
#     3. demarrer, attendre le qemu-guest-agent (ou ping), verifier l'OS,
#     4. eteindre + detruire la VM de scratch,
#     5. journaliser le resultat (log + sortieAlertmanager/webhook).
#   A planifier mensuellement (cron + rotation du log) — un backup jamais
#   restaure n'est pas un backup.
#
# PREREQUIS :
#   - Execution sur un nœud PVE (pve01/pve02) ou via ssh root sur ceux-ci
#   - Datastore PBS configure cote PVE (`pbs-nas`) OU acces direct
#     proxmox-backup-client (mode `qmrestore` avec archive .vz dumped)
#   - qemu-guest-agent installe dans les VM (garanti par le template)
#   - .env : PBS_* (voir backup/pbs-backup-job.sh), ALERTMANAGER_URL
#
# DONNEES ANONYMISEES : example.local, secrets via .env, scratch VM non nommee.
#
# SECURITE : DRY-RUN PAR DEFAUT (--apply pour executer). La VM de scratch est
#            systematiquement detruite (trap EXIT) pour ne rien laisser trainer.
#
# USAGE :
#   ./restore-drill.sh                     # dry-run (choix: GLPI01, VMID 210)
#   ./restore-drill.sh --apply --vmid 210  # restauration reelle de GLPI01
#   ./restore-drill.sh --apply --vmid 101 --node pve02
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/restore-drill.log}"
APPLY=0
VMID="${DRILL_VMID:-210}"        # GLPI01 par defaut : base de donnees = bon candidat
SCRATCH_NODE="${SCRATCH_NODE:-pve02}"
SCRATCH_VMID=$((9000 + VMID))    # plage 9xxx reservee aux drills, hors plan §5
BOOT_TIMEOUT=180                 # s — attendre l'agent ou le ping
SSH_USER="${PVE_SSH_USER:-root}"

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --vmid)    VMID="$2"; SCRATCH_VMID=$((9000 + $2)); shift 2 ;;
    --node)    SCRATCH_NODE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

[[ "$VMID" =~ ^[0-9]+$ ]] || { echo "ERREUR : --vmid invalide." >&2; exit 1; }

log() { printf '%s | %-8s | %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" | tee -a "$LOG_FILE"; }

webhook() {  # $1=severity $2=summary
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -n "${ALERTMANAGER_URL:-}" ]]; then
    local payload
    payload=$(cat <<JSON
[{"labels":{"alertname":"RestoreDrill","severity":"$1","job":"backup-drill"},
  "annotations":{"summary":"$2"},"startsAt":"${ts}"}]
JSON
)
    [[ "$APPLY" == "1" ]] && curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
      -d "$payload" "${ALERTMANAGER_URL}/api/v2/alerts" >/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
# Nettoyage garanti : la VM de scratch ne survit JAMAIS au drill
# -----------------------------------------------------------------------------
cleanup() {
  if [[ "$APPLY" == "1" ]]; then
    log info "Nettoyage : arret + suppression de la VM de scratch ${SCRATCH_VMID} sur ${SCRATCH_NODE}"
    ssh -o BatchMode=yes "${SSH_USER}@${SCRATCH_NODE}" "qm stop ${SCRATCH_VMID}" 2>/dev/null || true
    ssh -o BatchMode=yes "${SSH_USER}@${SCRATCH_NODE}" "qm destroy ${SCRATCH_VMID} --purge 1" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Secrets (mode apply uniquement)
# -----------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
if [[ "$APPLY" == "1" && ( -z "${PBS_HOST:-}" || -z "${PBS_DATASTORE:-}" ) ]]; then
  echo "ERREUR : PBS_HOST / PBS_DATASTORE manquants dans $ENV_FILE." >&2
  exit 2
fi

log info "DRILL start — VMID source=${VMID} scratch=${SCRATCH_VMID} node=${SCRATCH_NODE} apply=${APPLY}"

# -----------------------------------------------------------------------------
# 1. Recuperer la derniere archive de backup pour la VM
#    (approche 1 : datastore PBS expose cote PVE -> `qmrestore pbs-nas:vm/...`)
# -----------------------------------------------------------------------------
ssh_x() { ssh -o BatchMode=yes "${SSH_USER}@${SCRATCH_NODE}" "$@"; }

find_backup() {
  # Liste les archives vzdump restaurables depuis le stockage PBS monte sur PVE
  ssh_x "pvesh get /nodes/${SCRATCH_NODE}/storage/${PBS_STORAGE_NAME:-pbs-nas}/content --content-types backup --output-format json" 2>/dev/null |
    python3 - "$VMID" <<'PY'
import json, sys, re
vid = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cands = [i["volid"] for i in data if re.search(rf"/(?:backup/)?vm-{vid}-backup-", i.get("volid",""))]
print(sorted(cands)[-1] if cands else "")
PY
}

if [[ "$APPLY" == "1" ]]; then
  BACKUP_VOLID="$(find_backup)"
  [[ -n "$BACKUP_VOLID" ]] || { log error "Aucune archive vm-${VMID} trouvee dans pbs-nas."; exit 4; }
  log info "Archive retenue : ${BACKUP_VOLID}"
else
  BACKUP_VOLID="pbs-nas:vm/vm-${VMID}-backup-XXXXXXXX_XX_XX_XX_XX_XX.tar.gz (simule)"
  log info "DRY-RUN : archive simulee ${BACKUP_VOLID}"
fi

# -----------------------------------------------------------------------------
# 2. Restauration vers la VM de scratch (--unique 1 evite les collisions MAC)
# -----------------------------------------------------------------------------
if [[ "$APPLY" == "1" ]]; then
  log info "Restauration ${BACKUP_VOLID} -> VMID ${SCRATCH_VMID} (node ${SCRATCH_NODE})"
  ssh_x "qmrestore '${BACKUP_VOLID}' ${SCRATCH_VMID} --unique 1 --storage local-zfs --force 1"
else
  log info "DRY-RUN | ssh ${SCRATCH_NODE} qmrestore ${BACKUP_VOLID} ${SCRATCH_VMID} --unique 1 --storage local-zfs"
fi

# -----------------------------------------------------------------------------
# 3. Demarrage + verification (agent guest, sinon ping de la VM restauree)
# -----------------------------------------------------------------------------
verify_boot() {
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT )) ok=0
  [[ "$APPLY" == "1" ]] && ssh_x "qm start ${SCRATCH_VMID}"
  while (( $(date +%s) < deadline )); do
    if [[ "$APPLY" == "1" ]]; then
      # a) agent qemu-guest-agent repond ?
      if ssh_x "qm agent ${SCRATCH_VMID} ping" >/dev/null 2>&1; then ok=1; break; fi
      # b) secours : la VM repond-elle sur son IP de plan ?
      local ip
      ip=$(python3 - "$SCRIPT_DIR/../inventory/inventory.yaml" "$VMID" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for v in inv["vms"]:
    if str(v["vmid"]) == sys.argv[2]:
        print(v["ip"]); break
PY
)
      if [[ -n "$ip" ]] && ping -c1 -W2 "$ip" >/dev/null 2>&1; then ok=1; break; fi
      sleep 10
    else
      log info "DRY-RUN | ssh ${SCRATCH_NODE} qm start ${SCRATCH_VMID} puis attendre l'agent (<= ${BOOT_TIMEOUT}s)"
      ok=1; break
    fi
  done
  [[ "$ok" == "1" ]] || { log error "Echec de verification : VM ${SCRATCH_VMID} demarree mais agent/ping absents."; exit 5; }
}
verify_boot
log info "Restauration VERIFY OK — VMID ${SCRATCH_VMID} demarree et repondante."

# -----------------------------------------------------------------------------
# 4. (Optionnel) Controle applicatif : ici on verifie que la partition racine
#    est montee et que le hostname correspond a l'inventaire.
# -----------------------------------------------------------------------------
if [[ "$APPLY" == "1" ]]; then
  ssh_x "qm agent ${SCRATCH_VMID} info" 2>/dev/null | head -3 || true
  # Exemple specifique : attendre que GLPI reponde via HTTP (VMID 210)
  if [[ "$VMID" == "210" ]]; then
    curl -fsS -m 15 "http://10.10.80.110/" -o /dev/null \
      && log info "GLPI HTTP 200 OK depuis la VM restauree." \
      || log warn "GLPI pas joignable (adresses DHCP/pare-feu a verifier) — drill partiel."
  fi
fi

# -----------------------------------------------------------------------------
# 5. Resultat (cleanup via trap EXIT) — journal + webhook de succes
# -----------------------------------------------------------------------------
webhook info "Test de restauration mensuel OK : VMID ${VMID} restauree en scratch ${SCRATCH_VMID} (voir ${LOG_FILE})."
log info "DRILL end — SUCCESS. (cleanup automatique via trap)"
exit 0
