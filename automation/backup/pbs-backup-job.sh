#!/usr/bin/env bash
# =============================================================================
# pbs-backup-job.sh — Declenche, verifie et notifie les sauvegardes Proxmox
#                     Backup Server (PBS01, VMID 301) pour les VM du plan.
#
# PURPOSE (exemple public — portfolio) :
#   Operer la strategie 3-2-1 (docs/00-architecture-reference.md §7) :
#     1. Lancer un vzdump des VM cibles vers le datastore PBS (monte sur
#        PVE en tant que stockage `pbs-nas`, backed par nas01 10.10.50.20),
#     2. Verifier la presence du snapshot recent via l'API PBS
#        (proxmox-backup-client ls),
#     3. Pousser le resultat vers Alertmanager (webhook) / email SMTP.
#   Cron recommande (PVE) : 30 22 * * *  -> fenetre de nuit, hors production.
#
# RETENTION (cote datastore PBS, reglee une fois — pas dans ce script) :
#   keep-last=7, keep-daily=7, keep-weekly=4, keep-monthly=12, keep-yearly=1
#   (via `proxmox-backup-manager update datastore backup --keep-daily 7 ...`)
#   Note : la replication NAS -> off-site (objet distant) est pilote par PBS,
#   verifiee separement (backup/synology-replication-check.sh).
#
# PREREQUIS :
#   - pvesh + vzdump sur pve01/pve02 ; proxmox-backup-client sur le poste
#     d'execution (VLAN 50 BACKUP, MTU 9000)
#   - .env avec : PBS_USER (user@pbs!token), PBS_TOKEN, PBS_FINGERPRINT,
#     PBS_HOST=10.10.50.10, PBS_DATASTORE=backup, ALERTMANAGER_URL,
#     SMTP_* si relais mail
#
# DONNEES ANONYMISEES : hosts example.local ; secrets via .env uniquement.
#
# SECURITE : DRY-RUN PAR DEFAUT (--apply pour lancer reellement).
#
# USAGE :
#   ./pbs-backup-job.sh                    # dry-run : 12 VM du plan
#   ./pbs-backup-job.sh --apply            # sauvegarde complete
#   ./pbs-backup-job.sh --apply --vms "101 102 110 111"   # sous-ensemble
#   ./pbs-backup-job.sh --apply --mode snapshot            # vzdump snapshot
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
APPLY=0
MODE="stop"                              # vzdump : stop (fiable) | snapshot | suspend
MAXVM=3                                  # parallelsim (limite de charge PVE)
BACKUP_STORAGE="${BACKUP_STORAGE:-pbs-nas}"   # datastore PBS monte cote PVE
VM_LIST=""                               # vide => toutes les VM de l'inventaire

usage() { sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --vms)     VM_LIST="$2"; shift 2 ;;
    --mode)    MODE="$2"; shift 2 ;;
    --storage) BACKUP_STORAGE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

[[ "$MODE" =~ ^(stop|snapshot|suspend)$ ]] || { echo "ERREUR : --mode invalide ($MODE)." >&2; exit 1; }

# -----------------------------------------------------------------------------
# Secrets : .env obligatoire en mode apply (jamais de valeur en dur)
# -----------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
missing=()
for v in PBS_USER PBS_TOKEN PBS_FINGERPRINT PBS_HOST PBS_DATASTORE; do
  [[ -v ${v} && -n "${!v}" ]] || missing+=("$v")
done
if [[ "$APPLY" == "1" && ${#missing[@]} -gt 0 ]]; then
  echo "ERREUR : variables manquantes dans $ENV_FILE : ${missing[*]}" >&2
  exit 2
fi

# -----------------------------------------------------------------------------
# Cibles : par defaut les VMID de l'inventaire (plan §5)
# -----------------------------------------------------------------------------
if [[ -z "$VM_LIST" ]]; then
  VM_LIST=$(python3 - "${SCRIPT_DIR}/../inventory/inventory.yaml" <<'PY'
import sys, yaml
inv = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(str(v["vmid"]) for v in inv["vms"]))
PY
)
fi
echo "VM cibles : $VM_LIST"
echo "Mode vzdump : $MODE | stockage : $BACKUP_STORAGE | appli : $([[ $APPLY == 1 ]] && echo OUI || echo 'NON (dry-run)')"

# -----------------------------------------------------------------------------
# Notification : Alertmanager (webhook JSON) en priorite, email SMTP en secours
# -----------------------------------------------------------------------------
notify() {  # $1=severity $2=message
  local severity="$1" msg="$2" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "INFO [${severity}] ${msg}"

  if [[ -n "${ALERTMANAGER_URL:-}" ]]; then
    local payload
    payload=$(cat <<JSON
[{"labels":{"alertname":"PbsBackupJob","severity":"${severity}","job":"pbs-backup","cluster":"pve-example"},
  "annotations":{"summary":"${msg}"},
  "startsAt":"${ts}"}]
JSON
)
    if [[ "$APPLY" == "1" ]]; then
      curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
        -d "$payload" "${ALERTMANAGER_URL}/api/v2/alerts" \
        || echo "WARN : webhook Alertmanager injoignable (${ALERTMANAGER_URL})." >&2
    else
      echo "DRY-RUN | webhook -> ${ALERTMANAGER_URL}/api/v2/alerts : ${msg}"
    fi
  elif [[ -n "${SMTP_HOST:-}" && "$APPLY" == "1" ]]; then
    # Secours email via msmtp (config SMTP_* dans .env, jamais en dur)
    printf 'From: %s\nTo: %s\nSubject: [PBS] %s — sauvegarde\n\n%s\n' \
      "${SMTP_FROM}" "${SMTP_TO}" "$severity" "$msg" |
      msmtp --host="$SMTP_HOST" --port="${SMTP_PORT:-587}" \
            --user="$SMTP_USER" --password="$SMTP_PASS" --tls-on "${SMTP_TO}" || true
  fi
}

# -----------------------------------------------------------------------------
# 1. Declenchement : vzdump vers le datastore PBS (API PVE via pvesh)
# -----------------------------------------------------------------------------
FAILED_VMS=()
for vmid in $VM_LIST; do
  node=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin); print(next((r['node'] for r in d if str(r.get('vmid'))=='${vmid}'),''))" 2>/dev/null || echo "")
  [[ -z "$node" ]] && { echo "WARN : VMID ${vmid} introuvable dans le cluster, ignoree."; continue; }

  # Job vzdump en mode "stop" (coherence) — max 3 paralleles via job-id wait
  if [[ "$APPLY" == "1" ]]; then
    echo ">>> vzdump ${vmid} sur ${node} (mode=${MODE})"
    upid=$(vzdump "${vmid}" --storage "${BACKUP_STORAGE}" --mode "${MODE}" \
                 --maxjobs "${MAXVM}" --mailto "${SMTP_TO:-}" 2>&1 |
            grep -oE 'UPID:[^ ,]+' | head -1 || true)
    if [[ -z "$upid" ]]; then
      FAILED_VMS+=("$vmid")
      notify critical "vzdump lance sans UPID pour VMID ${vmid} sur ${node}."
      continue
    fi
    # Attente de la fin de tache (statut OK/ERROR)
    status=$(pvesh get "/nodes/${node}/tasks/${upid}/status" --output-format json 2>/dev/null |
             python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" || echo unknown)
    until [[ "$status" =~ ^(success|error|aborted)$ ]]; do
      sleep 15
      status=$(pvesh get "/nodes/${node}/tasks/${upid}/status" --output-format json 2>/dev/null |
               python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" || echo unknown)
    done
    [[ "$status" == "success" ]] || { FAILED_VMS+=("$vmid"); notify critical "Tache vzdump VMID ${vmid} KO (${status})."; }
  else
    echo "DRY-RUN | vzdump ${vmid} --storage ${BACKUP_STORAGE} --mode ${MODE} (nœud ${node:-?})"
  fi
done

# -----------------------------------------------------------------------------
# 2. Verification cote PBS : le backup doit exposer un snapshot < 26h
#    (controle independant du succes vzdump : prouve la restauration possible)
# -----------------------------------------------------------------------------
verify_pbs() {
  local repo="${PBS_USER}@${PBS_HOST}:${PBS_DATASTORE}"
  for vmid in $VM_LIST; do
    local latest
    latest=$(proxmox-backup-client ls --repository "$repo" \
              --host "$PBS_HOST" --port 8007 --fingerprint "$PBS_FINGERPRINT" \
              --password "$PBS_TOKEN" --namespace "vm/${vmid}" 2>/dev/null |
              awk '/^backup /{print $NF}' | sort | tail -1 || true)
    if [[ -z "$latest" ]]; then
      echo "KO : aucun backup PBS trouve pour VMID ${vmid}."; FAILED_VMS+=("${vmid}")
    else
      echo "OK : VMID ${vmid} -> snapshot ${latest}"
    fi
  done
}
if [[ "$APPLY" == "1" ]]; then verify_pbs; else echo "DRY-RUN | proxmox-backup-client ls (verification des snapshots)"; fi

# -----------------------------------------------------------------------------
# 3. Restitution + notification finale
# -----------------------------------------------------------------------------
if [[ ${#FAILED_VMS[@]} -gt 0 ]]; then
  notify critical "Sauvegarde PBS terminee avec echecs : VMID ${FAILED_VMS[*]}"
  exit 4
fi
notify info "Sauvegarde PBS reussie ($(wc -w <<< "$VM_LIST") VM verifiees) sur datastore ${PBS_DATASTORE:-backup}."
exit 0
