# Référence d'architecture — source de vérité

> ⚠️ Document de référence. **Tous** les fichiers `docs/`, `configs/`, `diagrams/` et
> `automation/` de ce dépôt sont dérivés de ce plan. Toute adresse, VLAN, hostname ou
> version citée ailleurs doit correspondre à ce tableau.
>
> Données **anonymisées** : adresses publiques `PUBLIC_IP_REDACTED`, domaines
> `example.local`, identifiants/mots de passe fictifs. Ne jamais committer de secret réel.

---

## 1. Inventaire matériel

| # | Équipement | Modèle (réf.) | Rôle | Emplacement |
|---|------------|---------------|------|-------------|
| 1 | Core Switch | Aruba CX 6300 24SFP+ (VSF stack, 2×) | L3, routage inter-VLAN, uplink FW | Baie 1 |
| 2 | Access Switch | Aruba CX 6100 24G PoU 370W (#1) | Accès postes/points de diffusion | Zone A |
| 3 | Access Switch | Aruba CX 6100 24G PoU 370W (#2) | Accès postes/points de diffusion | Zone B |
| 4 | Access Switch | Aruba CX 6100 24G PoU 370W (#3) | Accès postes/points de diffusion | Zone C |
| 5 | Firewall/Router | WatchGuard Firebox M270 (FWWG) | Périmètre, NAT, routage, failover WAN | Baie 1 |
| 6 | NAS | Synology RS1221+ (DSM 7.2) | Cible de sauvegarde, partages, archive | Baie 1 |
| 7 | Serveur | HPE ProLiant DL380 Gen10 Plus (nœud `pve01`) | Hyperviseur Proxmox VE | Baie 1 |
| 8 | Serveur | HPE ProLiant DL380 Gen10 Plus (nœud `pve02`) | Hyperviseur Proxmox VE | Baie 1 |
| 9 | Routeur | Starlink (mode pont) | Opérateur satellite | Baie 1 |
| 10 | Routeur | MikroTik hEX S (RB750Gr3) | CPE Fibre Telma | Baie 1 |

Patch panels 24U : distribution LAN vers les 3 zones, raccordées aux switches d'accès.

---

## 2. Opérateurs (WAN)

| Opérateur | Support | Rôle | IP publique | Passerelle | Préfixe |
|-----------|---------|------|-------------|------------|---------|
| Orange FH | Fibre | **Principal** | `PUBLIC_IP_REDACTED` | `PUBLIC_GW_REDACTED` | WAN `/30` privé FAI |
| Telma | Fibre + MikroTik | **Secondaire** | `PUBLIC_IP_REDACTED` | `PUBLIC_GW_REDACTED` | WAN `/30` privé FAI |
| Starlink | Satellite + routeur (mode pont) | **Secours** | `PUBLIC_IP_REDACTED` | CGNAT | DHCP |

Politique de failover : **active/active/standby** — Orange + Telma en PBR (par application),
Starlink en standby pur (débit/latence variables, CGNAT sortant). Détail en
[`networking.md`](networking.md#failover-et-gestion-des-3-fai).

---

## 3. Plan VLAN

| VLAN ID | Nom | Préfixe | Passerelle (Core) | Usage |
|---------|-----|---------|-------------------|-------|
| 10 | `MGMT` | `10.10.10.0/24` | `10.10.10.1` | Admin réseau : switches, FW, AP, OOB |
| 15 | `CLUSTER` | `10.10.15.0/24` | `10.10.15.1` | Corosync Proxmox + stockage VM (MTU 9000) |
| 20 | `SERVERS` | `10.10.20.0/24` | `10.10.20.1` | Serveurs Windows, IP de service Proxmox |
| 30 | `USERS` | `10.10.30.0/24` | `10.10.30.1` | Postes filaires |
| 40 | `WIFI` | `10.10.40.0/22` | `10.10.40.1` | Clients WiFi corporate (`CORP-SSID`) |
| 50 | `BACKUP` | `10.10.50.0/24` | `10.10.50.1` | Traffic sauvegarde, NAS, PBS (MTU 9000) |
| 60 | `MONITORING` | `10.10.60.0/24` | `10.10.60.1` | Prometheus, Grafana, Alertmanager, Zabbix |
| 70 | `GUEST` | `10.10.70.0/22` | `10.10.70.1` | Invités WiFi (`GUEST-SSID`), NAT Internet seul |
| 80 | `APPS` | `10.10.80.0/24` | `10.10.80.1` | VM application métier + GLPI |
| 90 | `DMZ` | `10.10.90.0/28` | `10.10.90.1` | Reverse proxy / services publiés |

Trunks uplink : les ports vers le Core transportent VLAN 10,15,20,30,40,50,60,70,80,90.
Les access ports des switches d'accès portent VLAN 30 (data) + voix optionnelle.

---

## 4. Plan d'adressage IP (hôtes fixes)

### Infrastructure réseau
| Device | Hostname | IP | VLAN |
|--------|----------|-----|------|
| Core Switch (VSF) | `core-sw-01.example.local` | `10.10.10.2` | MGMT |
| Access #1 | `acc-sw-a1.example.local` | `10.10.10.11` | MGMT |
| Access #2 | `acc-sw-b1.example.local` | `10.10.10.12` | MGMT |
| Access #3 | `acc-sw-c1.example.local` | `10.10.10.13` | MGMT |
| WatchGuard (ext) | `fw.example.local` | `PUBLIC_IP_REDACTED` | WAN |
| WatchGuard (int) | — | `10.10.90.2` | DMZ (pied de sous-réseau DMZ) |
| WatchGuard (Core link) | — | `10.10.10.254` | MGMT (L3 interco) |
| Point d'accès WiFi | `ap-corpo-01` | DHCP (réservé `10.10.10.31`) | MGMT |

### Serveurs & VM
| Rôle | Hostname | IP | VLAN | OS / version |
|------|----------|-----|------|--------------|
| Hyperviseur nœud 1 | `pve01.example.local` | `10.10.20.10` | SERVERS | Proxmox VE 8.2 (corosync `10.10.15.10`) |
| Hyperviseur nœud 2 | `pve02.example.local` | `10.10.20.11` | SERVERS | Proxmox VE 8.2 (corosync `10.10.15.11`) |
| Contrôleur de domaine (primaire) | `DC01` | `10.10.20.101` | SERVERS | Windows Server 2022 Std |
| Contrôleur de domaine (réplica) | `DC02` | `10.10.20.102` | SERVERS | Windows Server 2022 Std |
| File Server | `FILE01` | `10.10.20.110` | SERVERS | Windows Server 2022 Std |
| WSUS | `WSUS01` | `10.10.20.111` | SERVERS | Windows Server 2022 Std |
| App métier | `APP01` | `10.10.80.101` | APPS | Debian 12 / runtime métier |
| GLPI | `GLPI01` | `10.10.80.110` | APPS | Debian 12 / GLPI 10.0.x |
| Proxmox Backup Server | `PBS01` | `10.10.50.10` | BACKUP | PBS 3.1 |
| NAS Synology | `nas01.example.local` | `10.10.50.20` | BACKUP | DSM 7.2 |
| Prometheus | `mon-prom-01` | `10.10.60.10` | MONITORING | Debian 12 |
| Grafana | `mon-graf-01` | `10.10.60.11` | MONITORING | Debian 12 |
| Alertmanager | `mon-alert-01` | `10.10.60.12` | MONITORING | Debian 12 |
| Zabbix Server | `mon-zbx-01` | `10.10.60.20` | MONITORING | Debian 12 / Zabbix 6.0 LTS |
| Reverse proxy (DMZ) | `dmz-rp-01` | `10.10.90.10` | DMZ | Nginx (Debian 12) |

### Réservés DHCP (pool dynamique)
| VLAN | Pool | Passerelle | DNS | Bail |
|------|------|-----------|-----|------|
| USERS 30 | `10.10.30.100–200` | `10.10.30.1` | `10.10.20.101,10.10.20.102` | 8h |
| WIFI 40 | `10.10.40.100–10.10.43.200` | `10.10.40.1` | `10.10.20.101,10.10.20.102` | 8h |
| GUEST 70 | `10.10.70.100–10.10.71.200` | `10.10.70.1` | FW (résolution limitée) | 4h |

> DHCP : `DC01`/`DC02` (scope Windows, mode résilient 50/50). Relay DHCP : le
> Core Aruba relaie (`ip helper-address`) les scopes vers les DC.

---

## 5. Machines virtuelles Proxmox — affectation

| VMID | Nom | Nœud | vCPU | RAM | Disque | VLAN |
|------|-----|------|------|-----|--------|------|
| 101 | DC01 | pve01 | 4 | 8 Go | 100 Go | 20 |
| 102 | DC02 | pve02 | 4 | 8 Go | 100 Go | 20 |
| 110 | FILE01 | pve01 | 4 | 16 Go | 1 To | 20 |
| 111 | WSUS01 | pve01 | 4 | 8 Go | 250 Go | 20 |
| 201 | APP01 | pve02 | 4 | 8 Go | 80 Go | 80 |
| 210 | GLPI01 | pve02 | 4 | 8 Go | 120 Go | 80 |
| 301 | PBS01 | pve01 | 4 | 8 Go | 200 Go (sys) | 50 |
| 401 | MON-PROM | pve02 | 2 | 4 Go | 120 Go | 60 |
| 402 | MON-GRAF | pve02 | 2 | 2 Go | 40 Go | 60 |
| 403 | MON-ALERT | pve02 | 1 | 1 Go | 20 Go | 60 |
| 410 | MON-ZBX | pve01 | 2 | 4 Go | 100 Go | 60 |
| 501 | DMZ-RP | pve02 | 1 | 1 Go | 30 Go | 90 |

Stockage : `local-zfs` (raid1 local HPE) + `nas-nfs` (VLAN 15, MTU 9000). PBS stocke
les backups sur le NAS via NFS/mount.

---

## 6. Conventions de nommage

- Hosts réseau : `<role>-<type>-<nn>.example.local`
- VM Windows : rôle court en MAJ (`DC01`, `FILE01`, `WSUS01`)
- VM Linux : domaine + rôle (`mon-prom-01`, `dmz-rp-01`)
- Ports : `1/1/1` sur Aruba (stack/member/port)
- VLAN : 2 chiffres, toujours préfixés `VLAN <id> <NOM>`

## 7. Stratégie 3-2-1 (résumé, détail dans [`backup.md`](backup.md))

- **3** copies : prod VM + PBS local + NAS (Snapshot Replication)
- **2** supports : ZFS datastore local + NFS/Synology
- **1** hors-site : réplication chiffrée NAS → storage objet distant (off-site)
- RPO/RTO par classe (Tier 0/1/2) — voir matrice [`backup.md`](backup.md)

## 8. Pile monitoring (résumé, détail dans [`monitoring.md`](monitoring.md))

- **Réseau** : SNMP v3 depuis Aruba/WatchGuard/MikroTik → `snmp_exporter` → Prometheus
- **Hôtes** : `node_exporter` (Linux), WMI/`windows_exporter` (Windows), `pve-exporter` (Proxmox)
- **Services** : `blackbox_exporter` (HTTP/TCP/DNS/ICMP), GLPI web, WSUS
- **Visualisation** : Grafana · **Alerting** : Alertmanager (mail + webhook)
- **Supervision ITIL** : Zabbix pour les règles réseau/système + GLPI pour tickets
