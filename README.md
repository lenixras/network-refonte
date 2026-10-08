<p align="center">
  <h1 align="center">Refonte Infrastructure Réseau & Système</h1>
  <p align="center">
    <em>Réalisation d'architecture réseau &amp; système d'entreprise — Network / System Engineer</em>
  </p>
  <p align="center">
    Aruba · WatchGuard · MikroTik · HPE · Synology · Proxmox · Windows Server · GLPI · Prometheus/Grafana
  </p>
</p>

---

Projet de **refonte complète** d'une infrastructure d'entreprise : du réseau (cœur,
accès, périmètre multi-FAI) à la virtualisation (Proxmox, Active Directory, services
métier, GLPI), en passant par la sécurité, la sauvegarde 3-2-1 et la supervision.

> 🔒 **Projet documenté avec données anonymisées.** Toutes les IP publiques sont
> `PUBLIC_IP_REDACTED`, le domaine interne est `example.local`, les mots de passe /
> clés / community strings / certificats sont des placeholders `<REDACTED>`. Aucune
> donnée client réelle.

---

## 🧭 Logique du projet

`Avant` → `Problématique` → `Architecture cible` → `Implémentation` → `Sécurité` →
`Backup` → `Monitoring` → `Résultats`

### 1. Avant (existant)
Réseau monolithique : un seul switch L2, pas de segmentation, services physiques
dispersés, un seul FAI sans redondance, sauvegardes ad-hoc sur disque externe,
aucune supervision, GLPI/jira non intégrés, AD partiel.

### 2. Problématique
- **SPOF** : pas de haute disponibilité (switch, FAI, serveur).
- **Sécurité** : flat network, pas de zonage, pas de NAC, patching non piloté.
- **Exploitation** : pas de sauvegarde fiable ni testée, pas de monitoring → pannes
  subies.
- **Scalabilité** : impossible d'ajouter des services sans risque.

### 3. Architecture cible
Segmentation par VLAN, cœur L3 redondant (VSF), périmètre WatchGuard à **3 FAI** en
failover, virtualisation **Proxmox** haute disponibilité, services Windows (AD/DNS/DHCP/
GPO/File/WSUS), **GLPI** pour l'ITIL, sauvegarde **3-2-1** (PBS + Synology + hors-site),
supervision **Prometheus/Grafana/Zabbix**.

### 4. Implémentation
Voir les docs et configs : [docs/](docs/) · [configs/](configs/) ·
[automation/](automation/).

### 5. Sécurité · 6. Backup · 7. Monitoring · 8. Résultats
Sections dédiées ci-dessous et dans [docs/security.md](docs/security.md),
[docs/backup.md](docs/backup.md), [docs/monitoring.md](docs/monitoring.md).

**Résultats mesurés** (objectifs atteint par la cible) :

| Indicateur | Avant | Cible |
|------------|-------|-------|
| Dispo réseau (FAI) | mono, SPOF | 3 FAI active/active/standby |
| Temps de rétablissement serveur | ~jours | RTO ≤ 2 h (Tier 0) |
| Perte de données acceptée | non défini | RPO 1 h (Tier 0) |
| Détection de panne | utilisateur au téléphone | alerte < 2 min (supervision) |
| Segmentation | flat network | 10 VLAN, défaut deny |
| Patching | manuel | WSUS piloté + GPO |

---

## 🗺️ Infrastructure

```
Postes / AP ──► Switch Access Aruba ──► Core Aruba (L3/VSF) ──► WatchGuard ──► Orange / Telma / Starlink ──► Internet
                                                ├── AD / DNS / File Server (Proxmox)
                                                ├── Application métier
                                                └── GLPI
                       NAS Synology + HPE ProLiant (Proxmox VE) ── Sauvegarde 3-2-1
```

| Élément | Quantité | Rôle |
|---------|:--------:|------|
| Core Switch **Aruba CX 6300** | 1 (VSF 2×) | Routage inter-VLAN, L3 |
| Switch Access **Aruba CX 6100** | 3 | Accès postes/AP, PoE |
| Firewall/Router **WatchGuard M270** | 1 | Périmètre, NAT, failover 3 FAI |
| NAS **Synology RS1221+** | 1 | Sauvegarde / stockage |
| Serveur **HPE ProLiant DL380 Gen10 Plus** | 2 | Proxmox VE cluster |
| **Orange FH** (fibre) | 1 | FAI principal |
| **Starlink** (+ routeur, mode pont) | 1 | FAI secours |
| **Fibre Telma** (+ **MikroTik** hEX S) | 1 | FAI secondaire |
| Patch panels | — | Distribution LAN 3 zones |

Détail complet (VLAN, IP, VMs) : [docs/00-architecture-reference.md](docs/00-architecture-reference.md).

### VLAN
`10 MGMT` · `15 CLUSTER` · `20 SERVERS` · `30 USERS` · `40 WIFI` · `50 BACKUP` ·
`60 MONITORING` · `70 GUEST` · `80 APPS` · `90 DMZ` — défaut **deny**, GUEST isolé.

---

## 🖥️ Virtualisation & services (Proxmox VE)

Cluster 2 nœuds + QDevice. VMs (VMID 101–501) :

| Service | VM | OS |
|---------|----|----|
| **Active Directory / DNS / DHCP / GPO** | DC01 / DC02 | Windows Server 2022 |
| **File Server** (SMB3/DFS, RBAC) | FILE01 | Windows Server 2022 |
| **WSUS** (patching piloté) | WSUS01 | Windows Server 2022 |
| **Application métier** | APP01 | Debian 12 |
| **GLPI** (tickets/incidents/interventions, auth AD) | GLPI01 | Debian 12 / GLPI 10 |
| **Proxmox Backup Server** | PBS01 | PBS 3.1 |
| **Monitoring** | MON-* | Debian 12 |

→ [docs/virtualization.md](docs/virtualization.md)

---

## 🔐 Sécurité

Defense en profondeur : WatchGuard (SPI, TLS inspection, blocklists, publication via DMZ
uniquement), segmentation VLAN (défaut deny, GUEST isolé), WiFi **802.1X + RADIUS/NPS**,
**LAPS** + **MFA** sur les comptes privilégiés, RBAC, DHCP snooping/DAI/BPDU guard,
**SNMP v3**, journalisation 12 mois, séparation des tâches et revue des droits.

→ [docs/security.md](docs/security.md) (modèle de menaces, matrice des flux, checklist prod)

---

## 💾 Backup

**3-2-1** : Proxmox → PBS (incrémental chiffré) → NAS Synology → **hors-site**, copie
**immutable** anti-rançongadie. RPO/RTO par tier (Tier 0 = RPO 1 h / RTO 2 h),
rétention 7j→5 ans, **tests de restauration mensuels** consignés en ticket GLPI.

→ [docs/backup.md](docs/backup.md)

---

## 📊 Monitoring

**Prometheus + Grafana + Alertmanager** (métriques, dashboards, alertes e-mail/webhook)
et **Zabbix** (règles réseau/système). Exporters : SNMP (Aruba/FW/MikroTik), node,
windows, pve, blackbox. L'alerte critique devient **incident GLPI** → intervention.

→ [docs/monitoring.md](docs/monitoring.md)

---

## 🧱 Stack complète

| Technologie | Rôle | Version (réf.) | Prérequis | Dépendances |
|-------------|------|----------------|-----------|-------------|
| **Aruba CX** | Switching L2/L3, VSF, inter-VLAN | AOS-CX 10.x | Alimentation/redondance, licences AP | Uplink vers WatchGuard, NTP, syslog |
| **WatchGuard** | Firewall périmètre, NAT, failover WAN | Fireware OS 13.x | Comptes admin + 2FA, licences (UTM) | 3 FAI, route retour Core, proxy |
| **MikroTik** | CPE Fibre Telma | RouterOS v7 | Mode pass-through/routé | Vers WatchGuard, pas d'expo WAN |
| **HPE ProLiant** | Serveurs physiques | DL380 Gen10 Plus / iLO | RAID, iLO, alim doubles | Proxmox VE |
| **Synology** | NAS sauvegarde/stockage | DSM 7.2 (Btrfs) | Volumes, iSCSI/NFS | PBS datastore, Snapshot Replication |
| **Proxmox VE** | Hyperviseur | 8.2 | Cluster corosync + QDevice, bridge/VLAN | Stockage, PBS, réseau |
| **Windows Server** | Système des VMs serveur | 2022 Standard | Static IP, jointure domaine | AD, DNS, DHCP |
| **Active Directory** | Annuaire / authentification | 2022 (forest 2016+) | DC redondants | DNS, Kerberos, GPO |
| **DNS** | Résolution / SRV | AD-integrated | Forwarders via FW | AD, DHCP |
| **GPO** | Stratégies de groupe | AD-integrated | GPOLink, LAPS | AD, WSUS, File mapping |
| **WSUS** | Patching piloté | 2022 | Sync upstream, anneaux | GPO, AD |
| **GLPI** | Tickets/incidents ITIL | 10.0.x | MariaDB/PHP, auth LDAP/AD | AD, reverse proxy DMZ |
| **Backup** | PBS + Synology | PBS 3.1 / Hyper Backup | Chiffrement, immutabilité | Proxmox, NAS, hors-site |
| **Monitoring** | Observabilité | Prometheus/Grafana/Zabbix 6.0 | Exporters, SNMP v3 | Réseau, hôtes, services, backup |

---

## 📁 Structure du dépôt

```
network-refonte/
├── README.md
├── LICENSE
├── docs/                     # Documentation (architecture, réseau, sécurité, virtualisation, backup, monitoring, operations)
│   └── 00-architecture-reference.md   # source de vérité (VLAN/IP/hôtes/VMs)
├── diagrams/                 # Mermaid statiques (topologie, proxmox, flux, backup, monitoring)
│   └── animated/             # Animations SVG/CSS/JS (prefers-reduced-motion)
├── configs/                  # Exemples de configuration (Aruba, WatchGuard, MikroTik, Proxmox, Synology, Windows)
├── automation/               # Scripts (provisioning, backup, monitoring, inventaire)
└── screenshots/              # Captures d'interface (anonymisées)
```

### 🎬 Diagrammes animés (motion)
Ouvrir les fichiers HTML dans un navigateur — `diagrams/animated/` :

| Animation | Ce qu'elle montre |
|-----------|-------------------|
| `poste-switch-core-fw-internet.html` | Paquet Poste → Switch → Core → FW → Internet |
| `failover-3-fai.html` | Bascule Orange → Telma → Starlink sur panne |
| `poste-ad-dns.html` | Auth AD + résolution DNS + accès fichier |
| `proxmox-vm.html` | Hôtes/VMs + live migration |
| `vm-backup-nas.html` | Pipeline VM → PBS → NAS → hors-site |
| `monitoring-alert.html` | Métrique → Prometheus → Alertmanager → IT |
| `user-glpi-ticket.html` | Cycle ticket GLPI → intervention → clôture |

Tous respectent `prefers-reduced-motion` (état statique sans animation).

---

## 🧰 Démarrage rapide

```bash
# Parcourir la doc
open docs/00-architecture-reference.md

# Visualiser une animation (ouvrir dans un navigateur)
xdg-open diagrams/animated/failover-3-fai.html

# Valider un script d'automatisation en dry-run (aucune action réelle)
bash automation/provisioning/proxmox-create-vms.sh   # dry-run par défaut
```

Les scripts sont des **exemples** à valeurs anonymisées ; ils ne sont pas exécutables
tels quels contre une infra réelle sans secrets et adaptions.

---

## 📚 Documentation officielle

Uniquement les documentations officielles des technologies utilisées :

- **Aruba (HPE Networking)** — https://www.arubanetworks.com/resources/ (AOS-CX guides)
- **WatchGuard** — https://www.watchguard.com/help/docs/default-en-us/
- **Proxmox VE** — https://pve.proxmox.com/pve-docs/
- **HPE ProLiant / iLO** — https://support.hpe.com/hpesc/public/home
- **Synology DSM** — https://www.synology.com/en-global/knowledgebase/DSM
- **Microsoft (Windows Server / AD / DNS / DHCP / GPO / WSUS)** — https://learn.microsoft.com/windows-server/
- **GLPI** — https://glpi-install.readthedocs.io/ · admin https://glpi-user-documentation.readthedocs.io/
- **MikroTik** — https://help.mikrotik.com/docs/
- **Mermaid** (diagrammes) — https://mermaid.js.org/
- **Draw.io / diagrams.net** — https://www.drawio.com/doc/

_Outils de supervision_ : Prometheus https://prometheus.io/docs/ · Grafana
https://grafana.com/docs/ · Zabbix https://www.zabbix.com/documentation

---

## 🔒 Politique d'anonymisation

| Élément | Représentation |
|---------|----------------|
| IP publiques | `PUBLIC_IP_REDACTED` / `PUBLIC_GW_REDACTED` |
| Domaine interne | `example.local` (NetBIOS `EXAMPLE`) |
| IPs privées | préfixe `10.10.x.0/24` (RFC1918, fictif) |
| Mots de passe / secrets | `<REDACTED>`, `CHANGEME****`, variables d'env |
| API keys / tokens | `${...}` lu depuis `.env` (exclu du dépôt) |
| Certificats / clés privées | jamais commités |
| Communautés SNMP / RADIUS | placeholders |
| Infos clients / noms réels | aucun |

`.gitignore` exclut `.env`, clés privées, certificats et captures non floutées.

---

## ⚠️ Avertissement

Projet **réel**, publié avec des **données anonymisées**. Les configurations et scripts
sont des extraits représentatifs de la réalisation ; ils ne doivent pas être appliqués
tels quels sur une autre infrastructure sans revue, tests et secrets valides. Les marques
citées appartiennent à leurs éditeurs respectifs.

---

## 📄 Licence

MIT — voir [LICENSE](LICENSE).
