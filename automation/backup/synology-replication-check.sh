#!/usr/bin/env bash
# =============================================================================
# synology-replication-check.sh — Verifie que la replication Snapshot
#   Replication du NAS Synology (nas01, 10.10.50.20, VLAN 50) est fraiche,
#   et alerte si elle est obsolete (maillon NAS -> off-site de la 3-2-1).
#
# PURPOSE (exemple publié — données anonymisées) :
#   Interroger l'API DSM 7.2 (port 5001 HTTPS) pour lire la date de
#   derniere execution de chaque tache Snapshot Replication, et declencher
#   une alerte si lastRun > seuil (defaut 26 h : tolerance d'un cycle
#   quotidien + marge). Cron recommande : every 4 h.
#
# PREREQUIS :
#   - Sur le NAS : tache Snapshot Replication creee (plan : quotidien),
#     API autorisee pour le compte/tokens, IP du poste d'execution en
#     autorisation d'acces DSM.
#   - curl + jq ; .env avec SYNO_HOST/SYNO_PORT/SYNO_TOKEN (API token DSM 7)
#     ou SYNO_USER/SYNO_PASSWORD en secours (session SYNO.API.Auth).
#   - NE PAS DESACTIVER le verify TLS : token caisse dans .env, pas en dur.
#
# NOTE API : le nom exact des methodes Snapshot Replication varie selon la
#   version de DSM/package ; ce script utilise `SYNO.Storage.CGI.Snapshot`
#   en exemple — verifier la reference Synology API de votre version avant
#   mise en production (fallback : lecture du fichier de log de la tache).
#
# DONNEES ANONYMISEES : NAS en VLAN 50 interne ; secrets via .env.
#
# SECURITE : lecture seule (GET uniquement). --dry-run affiche les requetes.
#
# USAGE :
#   ./synology-replication-check.sh                # check reel + alerte
#   ./synology-replication-check.sh --dry-run      # montre les appels curl
#   ./synology-replication-check.sh --max-age-hours 30
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../.env}"
MAX_AGE_HOURS="${REPLICATION_MAX_AGE_HOURS:-26}"
DRY_RUN=0
API_PATH="/webapi/entry.cgi"

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --max-age-hours)   MAX_AGE_HOURS="$2"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

[[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || { echo "ERREUR : --max-age-hours doit etre un entier." >&2; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : binaire manquant : $bin" >&2; exit 2; }
done

# -----------------------------------------------------------------------------
# Secrets DSM via .env (jamais en dur)
# -----------------------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
: "${SYNO_HOST:=10.10.50.20}"       # nas01.example.local — VM/NAS du plan §4
BASE_URL="https://${SYNO_HOST}:${SYNO_PORT:-5001}"

SYNO_SESSION=""
login() {
  # En dry-run : aucune credential requise (les appels curl sont simules)
  if [[ "$DRY_RUN" == "1" ]]; then return 0; fi
  # Priorite : token API DSM 7 (en-tete Authorization) ; secours : session Auth
  if [[ -n "${SYNO_TOKEN:-}" ]]; then
    return 0   # le token est passe en en-tete sur chaque appel
  fi
  if [[ -z "${SYNO_USER:-}" || -z "${SYNO_PASSWORD:-}" ]]; then
    echo "ERREUR : SYNO_TOKEN ou (SYNO_USER+SYNO_PASSWORD) requis dans $ENV_FILE." >&2
    exit 2
  fi
  local resp
  # TLS verifie : fournir la CA interne via SYNO_CA_BUNDLE dans .env
  local tlsargs=(--cacert "${SYNO_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}")
  resp=$(curl -fsS -m 15 "${tlsargs[@]}" -G "$BASE_URL$API_PATH" \
    --data-urlencode "api=SYNO.API.Auth" --data-urlencode "version=6" \
    --data-urlencode "method=login" --data-urlencode "session=Storage" \
    --data-urlencode "format=sid" \
    --data-urlencode "account=${SYNO_USER}" --data-urlencode "passwd=${SYNO_PASSWORD}")
  SYNO_SESSION=$(jq -r '.data.sid // empty' <<<"$resp")
  [[ -n "$SYNO_SESSION" ]] || { echo "ERREUR : login DSM refuse (code: $(jq -r '.error.code // "?"' <<<"$resp"))." >&2; exit 3; }
}

dsm_get() {  # $1=api $2=version $3=method [$4=json supplementaire...]
  local api="$1" ver="$2" meth="$3"; shift 3
  local args=(-G "$BASE_URL$API_PATH"
    --data-urlencode "api=${api}" --data-urlencode "version=${ver}"
    --data-urlencode "method=${meth}")
  while [[ $# -gt 0 ]]; do args+=(--data-urlencode "$1"); shift; done
  [[ -n "$SYNO_SESSION" ]] && args+=(--data-urlencode "_sid=${SYNO_SESSION}")
  local hdr=()
  [[ -n "${SYNO_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${SYNO_TOKEN}")

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN | curl ${hdr[*]:-} ${args[*]}"
    echo '{"success":true,"data":{"tasks":[]}}'
    return 0
  fi
  curl -fsS -m 20 --cacert "${SYNO_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}" \
    "${hdr[@]}" "${args[@]}"
}

# -----------------------------------------------------------------------------
# 1. Lister les taches de replication + derniere execution
# -----------------------------------------------------------------------------
login
RESP="$(dsm_get "SYNO.Storage.CGI.Snapshot.Replication" 1 "get_task" \
        "type=replication_task" )"   # nom d'API EXEMPLE — cf. note en-tete

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY-RUN : check de fraicheur saisi sur un echantillon vide."
  exit 0
fi

NOW=$(date +%s)
STALE_TASKS=()
mapfile -t TASKS < <(jq -c '.data.tasks[]? // .data[]? // empty' <<<"$RESP")

if [[ ${#TASKS[@]} -eq 0 ]]; then
  echo "WARN : aucune tache de replication remontee (API/version differente ? verifier la doc Synology)." >&2
  exit 0
fi

for t in "${TASKS[@]}"; do
  name=$(jq -r '.name // .task_name // "inconnu"' <<<"$t")
  last_epoch=$(jq -r '.last_run_time // .lastExecutedTime // 0' <<<"$t")
  status=$(jq -r '.status // .last_status // "?"' <<<"$t")
  age_h=$(( (NOW - last_epoch) / 3600 ))
  if (( last_epoch == 0 || age_h > MAX_AGE_HOURS || status == "fail" )); then
    STALE_TASKS+=("$name (age=${age_h}h, statut=${status})")
    echo "KO : replication ${name} obsolete/echouee (age ${age_h} h > ${MAX_AGE_HOURS} h)."
  else
    echo "OK : ${name} — derniere execution il y a ${age_h} h (statut ${status})."
  fi
done

# -----------------------------------------------------------------------------
# 2. Alerte via Alertmanager (webhook) — meme contrat que pbs-backup-job.sh
# -----------------------------------------------------------------------------
if [[ ${#STALE_TASKS[@]} -gt 0 ]]; then
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PAYLOAD=$(cat <<JSON
[{"labels":{"alertname":"SynologyReplicationStale","severity":"critical","job":"backup","nas":"nas01"},
  "annotations":{"summary":"Replication NAS obsolete : ${STALE_TASKS[*]} (seuil ${MAX_AGE_HOURS}h)"},
  "startsAt":"${TS}"}]
JSON
)
  if [[ -n "${ALERTMANAGER_URL:-}" ]]; then
    curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
      -d "$PAYLOAD" "${ALERTMANAGER_URL}/api/v2/alerts" || echo "WARN : webhook indisponible." >&2
  fi
  echo "RESULTAT : CRITIQUE (${#STALE_TASKS[@]} tache(s) en defaut)."
  exit 4
fi
echo "RESULTAT : OK — toutes les replications sont fraiches."
exit 0
