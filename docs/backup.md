# Sauvegarde — stratégie 3-2-1

## 1. Principe 3-2-1

| Règle | Mise en œuvre |
|-------|---------------|
| **3 copies** des données | Prod (VM/donnée) + PBS local + NAS Synology |
| **2 supports différents** | ZFS local (SSD/NVMe) + NFS/Synology (Btrfs) + objet hors-site |
| **1 copie hors-site** | Réplication chiffrée NAS → stockage objet distant (off-site) |

Bonus anti-rançongadie : **copie immutable** (WORM/`retention lock` Synology + PBS
prune-after) et **air-gap logique** (compte de réplication séparé, pas de write-back direct
depuis le LAN).

```
VMs Proxmox ──(PBS incrémental,chiffré)──► PBS01 (10.10.50.10)
                                             │  datastore sur NAS
Données FILE01/AD/APP/GLPI ──(Veeam-agent/robocopy)──► NAS (10.10.50.20)
                                             │
                          Snapshot Replication│  (chiffré, immuable)
                                             ▼
                                      Off-site (objet distant)
```

## 2. Périmètre

- **VMs Proxmox** : backup full+incrémental via **PBS** (toutes les VMID 101..501).
- **Windows** : AD (System State sur DC01/DC02), FILE01 (DFS/partages via Veeam agent ou
  `wbadmin`), WSUS01 (content DB).
- **Linux** : APP01 (app + DB dump), GLPI01 (base MariaDB + `/glpi/files`).
- **Config réseau** : sauvegarde des configurations Aruba/WatchGuard/MikroTik/NAS (script
  periodic + dépôt privé hors-ligne), versionnée.

## 3. RPO / RTO par classe

| Tier | Contenu | RPO | RTO | Fréquence backup | Exemples |
|------|---------|-----|-----|------------------|----------|
| **Tier 0** | AD/DNS/DHCP, APP01, GLPI01, PBS, NAS | **1 h** | **≤ 2 h** | 1 h (incr.) + 1 j (full) | DC01/02, APP01, GLPI01 |
| **Tier 1** | FILE01, WSUS01, reverse proxy | 4 h | ≤ 8 h | toutes les 4 h | FILE01, WSUS01, DMZ-RP |
| **Tier 2** | MON-*, VMs non critiques | 24 h | ≤ 24 h | quotidien | Prometheus/Grafana/Zabbix |

> RPO = perte max acceptée (intervalle entre 2 backups). RTO = temps max de rétablissement.
> Les cibles Tier0 supposent PBS incrémental horaire + live-restore.

## 4. Rétention

| Niveau | Rétention |
|--------|-----------|
| Incrémental | 7 jours glissants |
| Full hebdo | 4 semaines |
| Mensuel | 12 mois |
| Annuel/archival | 5 ans (conformité, sur NAS/archive) |
|PBS prune-after | 30 jours sur datastore primary |
| Config réseau | 90 versions |

## 5. Outils

- **Proxmox Backup Server 3.1** (`PBS01`) : backup/restore VMs, dédup, chiffrement,
  live-restore, verify jobs.
- **Synology DSM 7.2** (`nas01`) : Hyper Backup + **Snapshot Replication** vers hors-site,
  Btrfs, retention lock (immutable), iSCSI/NFS.
- **Veeam Agent / wbadmin** pour System State AD et les workloads Windows.
- Scripts : `automation/backup/pbs-backup-job.sh` (lance/vérifie),
  `restore-drill.sh` (test), `synology-replication-check.sh` ( freshness).

## 6. Tests de restauration (obligatoires, planifiés)

Fréquence : **mensuel** sur un échantillon + **trimestriel** complet.

1. **Restore VM** depuis PBS vers une VM scratch (VMID temporaire), boot + service check.
2. **System State / AD** : restauration authoritative/non-authoritative en environnement
   isolé, vérification `dcdiag`.
3. **Fichier** : restauration d'un partage FILE01 + intégrité checksum.
4. **GLPI/APP** : restore base + upload file, ouverture d'un ticket de test.
5. **Hors-site** : restauration depuis la copie off-site pour valider la bande passante
   et le RTO réel.

Chaque test = **ticket GLPI** (traçabilité ITIL) + consigné (date, tiers, durée mesurée vs
RTO cible, succès/échec, actions correctives). Voir `automation/backup/restore-drill.sh`.

## 7. Chiffrement & accès

- Au repos : PBS chiffrement AES (clé de protection distincte), Btrfs + encryption Synology.
- En transit : TLS (réplication off-site, API PBS).
- Clés/secrets hors dépôt (`<REDACTED>`, coffre), séparation admin prod / admin backup.
- Comptes de réplication non utilisables pour un restore depuis le LAN (anti-ransomware).

## 8. Monitoring de la sauvegarde
- Alerte **backup job failed** et **réplication stale** (voir
  [`monitoring.md`](monitoring.md) et `automation/monitoring/prometheus/alerts/rules-network.yml`).
- Tableau de bord Grafana : succès/durée/taille des jobs, fraicheur hors-site.
