#!/usr/bin/env bash
# =============================================================================
# generate-inventory.sh — Génère un tableau Markdown d'inventaire depuis
#                         inventory.yaml (ou un CSV au même schéma).
#
# PURPOSE (exemple publié — données anonymisées) :
#   Industrialiser la doc d'inventaire : une seule source machine-readable
#   (inventory.yaml, alignée sur docs/00-architecture-reference.md) dont on
#   dérive le tableau Markdown intégré à la documentation.
#
# PREREQUIS :
#   - bash 4+, yq (version mikefaris v4 — syntaxe `yq -r`) ou, à défaut,
#     python3 + PyYAML en secours automatique
#   - lecture seule : le script n'écrit que sur stdout (réorienter si besoin)
#
# DONNÉES ANONYMISÉES :
#   - IP publiques : PUBLIC_IP_REDACTED ; domaine : example.local ;
#     aucun secret transité par ce script.
#
# USAGE :
#   ./generate-inventory.sh                       # inventory.yaml par défaut
#   ./generate-inventory.sh -i chemin/vers.csv    # import CSV
#   ./generate-inventory.sh -i inventory.yaml -o inventaire.md
#
#   Régenerer la doc :
#     ./generate-inventory.sh > ../docs/inventaire-auto.md
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration par défaut
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="${SCRIPT_DIR}/inventory.yaml"
OUTPUT=""

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)  INPUT="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -h|--help)   usage 0 ;;
    *) echo "Option inconnue : $1" >&2; usage 1 ;;
  esac
done

if [[ ! -f "$INPUT" ]]; then
  echo "ERREUR : fichier d'inventaire introuvable : $INPUT" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Lecture YAML — yq v4 en priorité, python3/PyYAML en secours
# -----------------------------------------------------------------------------
read_yaml_rows() {
  local file="$1"
  if command -v yq >/dev/null 2>&1; then
    # Assemble : équipements réseau + hyperviseurs + VMs (ordre du plan)
    yq -r '
      [
        ((.network_devices // [])[] | [.name, (.hostname // "-"), .ip, (.vlan|tostring), .role, (.node // "-")]),
        ((.hypervisors // [])[]     | [.name, (.hostname // "-"), .ip, (.vlan|tostring), .role, (.node // "-")]),
        ((.vms // [])[]             | [.name, (.hostname // "-"), .ip, (.vlan|tostring), (.role + " (VMID " + (.vmid|tostring) + ")"), .node])
      ] | .[] | select(length > 0) | @tsv
    ' "$file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import csv, sys
try:
    import yaml
except ImportError:
    sys.exit("ERREUR : ni yq ni PyYAML (python3 -m pip install pyyaml) ne sont disponibles.")
with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
rows = []
for d in data.get("network_devices", []) or []:
    rows.append([d["name"], d.get("hostname") or "-", d["ip"], str(d["vlan"]), d["role"], d.get("node") or "-"])
for d in data.get("hypervisors", []) or []:
    rows.append([d["name"], d.get("hostname") or "-", d["ip"], str(d["vlan"]), d["role"], d.get("node") or "-"])
for d in data.get("vms", []) or []:
    rows.append([d["name"], d.get("hostname") or "-", d["ip"], str(d["vlan"]),
                 f"{d['role']} (VMID {d['vmid']})", d.get("node") or "-"])
w = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
w.writerows(rows)
PY
  else
    echo "ERREUR : yq (v4) ou python3+PyYAML requis pour lire le YAML." >&2
    exit 2
  fi
}

# -----------------------------------------------------------------------------
# Lecture CSV — colonnes attendues : name,hostname,ip,vlan,role,node
# -----------------------------------------------------------------------------
read_csv_rows() {
  local file="$1"
  awk -F',' '
    NR==1 { next }                       # entête
    /^[[:space:]]*#/ { next }            # commentaires
    NF >= 4 {
      # name,hostname,ip,vlan,role,node  (role peut contenir des virgules -> on
      # limite le découpage : node = dernier champ si NF==6)
      if (NF == 6) printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6
      else if (NF == 5) printf "%s\t%s\t%s\t%s\t%s\t-\n", $1,$2,$3,$4,$5
      else printf "%s\t-\t%s\t%s\t%s\t-\n", $1,$3,$4,$5
    }' "$file"
}

emit_markdown() {
  echo ""
  echo "_Généré automatiquement par \`automation/inventory/generate-inventory.sh\` — source : \`$(basename "$INPUT")\` (aligné sur docs/00-architecture-reference.md). Données anonymisées._"
  echo ""
  echo "| Hôte | FQDN | IP | VLAN | Rôle | Nœud |"
  echo "|------|------|----|------|------|------|"
  local count=0
  while IFS=$'\t' read -r name hostname ip vlan role node; do
    [[ -z "${name:-}" ]] && continue
    echo "| \`${name}\` | ${hostname} | \`${ip}\` | ${vlan} | ${role} | ${node} |"
    count=$((count + 1))
  done
  echo ""
  echo "_Total : ${count} entrées._" >&2
}

# -----------------------------------------------------------------------------
# Exécution
# -----------------------------------------------------------------------------
case "$INPUT" in
  *.csv)
    echo "INFO : import CSV depuis $INPUT" >&2
    rows="$(read_csv_rows "$INPUT")"
    ;;
  *.yaml|*.yml)
    echo "INFO : import YAML depuis $INPUT" >&2
    rows="$(read_yaml_rows "$INPUT")"
    ;;
  *)
    echo "ERREUR : extension non gérée (attendu .yaml/.yml/.csv) : $INPUT" >&2
    exit 1
    ;;
esac

if [[ -z "$rows" ]]; then
  echo "ERREUR : aucune ligne exploitable dans $INPUT (schéma attendu ?)" >&2
  exit 3
fi

if [[ -n "$OUTPUT" ]]; then
  printf '%s\n' "$rows" | emit_markdown > "$OUTPUT"
  echo "OK : inventaire écrit dans $OUTPUT" >&2
else
  printf '%s\n' "$rows" | emit_markdown
fi
