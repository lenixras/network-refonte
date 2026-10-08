# automation/ — Scripts d'exploitation du reference design example.local

Atelier d'**automatisation** dérivé du plan d'architecture
([`docs/00-architecture-reference.md`](../docs/00-architecture-reference.md) :
source de vérité absolue). Il couvre le cycle de vie complet de la refonte :
inventaire, provisionnement, sauvegarde/restauration et monitoring.

> ⚠️ **Ces scripts sont extraits de la réalisation, publiés avec données anonymisées.** Ils sont
> réalistes et défensifs (dry-run par défaut, `set -euo pipefail`, contrôles
> de cohérence), mais **toutes les données sont anonymisées** :
> IP publiques → `PUBLIC_IP_REDACTED`, domaine → `example.local`, NetBIOS →
> `EXAMPLE`, secrets → variables d'environnement (`.env`) **jamais en dur**.
> Ne les exécutez pas sur une infrastructure de production sans relecture.

---

## Arborescence

```text
automation/
├── .env.example                      # modèle de toutes les variables requises
├── README.md                         # ce fichier
├── inventory/
│   ├── inventory.yaml                # inventaire machine-readable (VMs 101..501 + réseau)
│   └── generate-inventory.sh         # -> tableau Markdown (hôte, IP, VLAN, rôle, nœud)
├── provisioning/
│   ├── proxmox-create-vms.sh         # qm clone du template cloud-init, plan §5 strict
│   ├── windows-dc-promote.ps1        # AD DS/DNS/DHCP + forêt example.local (DC01/DC02)
│   └── dhcp-scopes.ps1               # scopes USERS/WIFI/GUEST (plages/options/baux du plan)
├── backup/
│   ├── pbs-backup-job.sh             # vzdump -> PBS + vérif snapshots + webhook Alertmanager
│   ├── restore-drill.sh              # le « test de restauration » mensuel automatisé
│   └── synology-replication-check.sh # fraicheur Snapshot Replication nas01 (API DSM)
└── monitoring/
    ├── deploy-exporters.yml          # Ansible : node/windows/pve/blackbox/snmp exporters
    ├── inventory/hosts.ini           # inventaire Ansible (mêmes IP que le plan)
    ├── prometheus/
    │   ├── prometheus.yml            # scrape_configs ciblant les IP exactes du plan
    │   ├── blackbox/blackbox.yml     # modules http/tcp/icmp/dns/tls
    │   └── alerts/rules-network.yml  # liens, CPU/RAM PVE, backup, GLPI, WSUS, certificats
    ├── grafana/provisioning/
    │   ├── datasources/datasource.yml   # Prometheus 10.10.60.10 + Alertmanager .12
    │   └── dashboards/dashboards.yml    # provider as-code
    └── snmp/snmp-v3.md               # SNMPv3 Aruba/WatchGuard/MikroTik/Synology (env)
```

## Prérequis

| Outil | Version | Utilisé par |
|-------|---------|-------------|
| bash | 4+ | scripts d'automatisation |
| `yq` (mikefaris v4) **ou** python3 + PyYAML | — | `inventory/`, `provisioning/` |
| `jq`, `curl` | — | `backup/`, webhooks |
| Proxmox VE 8.2 (`pvesh`, `qm`, `vzdump`, `qmrestore`) + PBS 3.1 (`proxmox-backup-client`) | — | `provisioning/proxmox-create-vms.sh`, `backup/` |
| PowerShell (Windows Server 2022) | 5.1+ | `provisioning/*.ps1` |
| Ansible | core 2.16+ | `monitoring/deploy-exporters.yml` |
| SSH root pve01/pve02, WinRM pour les DC, accès VLAN 50/60 | — | execution |

Mise en place des secrets :

```bash
cd network-refonte/automation
cp .env.example .env
chmod 600 .env        # UNIQUEMENT sur la machine d'exploitation — jamais commit
```

## Utilisation (ordre logique de déploiement)

```bash
# 0. Générer la doc d'inventaire Markdown depuis l'YAML
./inventory/generate-inventory.sh > ../docs/inventaire.md

# 1. Créer les 12 VM du plan (VMID 101..501) — DRY-RUN par défaut
./provisioning/proxmox-create-vms.sh
./provisioning/proxmox-create-vms.sh --apply

# 2. Promouvoir DC01 (forêt example.local) puis DC02 (réplica) — sur les VM
.\provisioning\windows-dc-promote.ps1 -Role Primary -Ipv4 10.10.20.101 -WhatIf
.\provisioning\dhcp-scopes.ps1 -WhatIf

# 3. Sauvegardes (cron suggéré 30 22 * * *) + test de restauration mensuel
./backup/pbs-backup-job.sh --apply
./backup/restore-drill.sh --apply --vmid 210
./backup/synology-replication-check.sh

# 4. Déployer la pile d'exporters puis charger Prometheus/Grafana as-code
ansible-playbook -i monitoring/inventory/hosts.ini monitoring/deploy-exporters.yml --check --diff
```

## Notes de sécurité

- **Dry-run par défaut** : `proxmox-create-vms.sh`, `pbs-backup-job.sh` et
  `restore-drill.sh` n'agissent qu'avec `--apply` ; les scripts PowerShell
  sont `SupportsShouldProcess` (`-WhatIf`).
- **Aucun secret en dur** : les scripts refusent `--apply` si `.env` est
  incomplet. Les passphrases SNMP/RADIUS, tokens PBS/GLPI/DSM et SMTP sont
  lus depuis l'environnement. `.env` est à ajouter au `.gitignore`.
- **Cohérence du plan** : chaque script re-vérifie les IP/VMID contre
  `inventory/inventory.yaml` (déduit de `docs/00-architecture-reference.md`) ;
  une IP hors plan fait échouer le script, pas de silence.
- **Nettoyage garanti** : `restore-drill.sh` détruit sa VM de scratch via
  `trap EXIT` ; la VMID 9xxx utilisée pour les drills est hors plan §5.
- Les scripts supposent le **MTU 9000** sur VLAN 15/50 (cluster + backup) et
  les ACL SNMP/monitoring VLAN 10/60 décrites dans le plan.

## Limites assumées (exemple public)

- `inventory.yaml` porte la convention locale « template cloud-init VMID 9000 »
  (hors plan) — à adapter.
- Le nom exact des API DSM *Snapshot Replication* varie selon les versions ;
  le script documente le point à vérifier.
- Le module MikroTik du `snmp_exporter` est commenté : le plan ne publie pas
  d'IP de management du CPE (derrière le WatchGuard).
