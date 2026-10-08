# Diagrammes — refonte réseau & systèmes

> Source de vérité : [`docs/00-architecture-reference.md`](../docs/00-architecture-reference.md).
> Données anonymisées : adresses publiques `PUBLIC_IP_REDACTED`, domaine `example.local`.
> Chaque diagramme existe en fichier `.mmd` (Mermaid v10) et est rendu ci-dessous.
> Les versions **animées** (SVG + CSS + JS autonomes) sont dans [`animated/`](animated/README.md).

## Index

| Diagramme | Fichier | But |
|-----------|---------|-----|
| Topologie Physique | [`topologie-physique.mmd`](./topologie-physique.mmd) | Topologie physique : patch panels, Core Aruba VSF, 3 switches d'accès, WatchGuard, 3 FAI, NAS et les 2 serveurs HPE ProLiant. |
| Topologie Logique | [`topologie-logique.mmd`](./topologie-logique.mmd) | Segmentation VLAN 10 à 90 avec sous-réseaux, passerelles SVI et placement des hôtes/VM dans chaque VLAN. |
| Architecture Proxmox | [`architecture-proxmox.mmd`](./architecture-proxmox.mmd) | Cluster Proxmox VE 8.2 pve01/pve02 : bridges vmbr0/vmbr1, stockage local-zfs + nas-nfs + datastore PBS, affectation des VMID 101 à 501. |
| Flux Lan Wan | [`flux-lan-wan.mmd`](./flux-lan-wan.mmd) | Flux LAN→WAN : poste → accès → core puis serveurs/apps/GLPI, et core → WatchGuard → FAI → Internet. |
| Flux Utilisateur | [`flux-utilisateur.mmd`](./flux-utilisateur.mmd) | Séquence utilisateur : DHCP/ouverture de session, authentification AD, DNS, SMB vers FILE01, HTTP vers l'app métier. |
| Flux Internet | [`flux-internet.mmd`](./flux-internet.mmd) | Séquence Internet : sortants NAT/PAT + failover 3 FAI, entrants GLPI publié via reverse proxy DMZ. |
| Backup | [`backup.mmd`](./backup.mmd) | Chaîne de sauvegarde 3-2-1 : VM prod → PBS01 → NAS Synology → réplication chiffrée hors-site, avec rétention GFS. |
| Monitoring | [`monitoring.mmd`](./monitoring.mmd) | Pile de supervision : exporters → Prometheus → Grafana/Alertmanager → notifications, Zabbix et SNMP v3 vers les équipements réseau. |

---

## topologie-physique.mmd

Topologie physique : patch panels, Core Aruba VSF, 3 switches d'accès, WatchGuard, 3 FAI, NAS et les 2 serveurs HPE ProLiant.

```mermaid
%% Topologie physique — source de vérité : docs/00-architecture-reference.md
%% Toutes les adresses/hôtes sont anonymisés (PUBLIC_IP_REDACTED, example.local).
flowchart TD
    subgraph WAN["Opérateurs Internet (WAN)"]
        ORANGE["Orange FH — Fibre — principal — PUBLIC_IP_REDACTED"]
        TELMA["Telma — Fibre via MikroTik hEX S RB750Gr3 — secondaire — PUBLIC_IP_REDACTED"]
        STAR["Starlink — Satellite, routeur en mode pont — secours — PUBLIC_IP_REDACTED"]
    end

    subgraph BAIE["Baie 1 — cœur d'infrastructure"]
        FW["WatchGuard Firebox M270 (FWWG) — périmètre, NAT, failover WAN"]
        CORE["Core Aruba CX 6300 24SFP+ — pile VSF 2 membres — core-sw-01 · 10.10.10.2"]
        PP["Patch panels 24U — distribution LAN vers les 3 zones"]
        NAS["NAS Synology RS1221+ — nas01 · 10.10.50.20 — DSM 7.2"]
        PVE1["HPE ProLiant DL380 Gen10 Plus — pve01 · 10.10.20.10 — Proxmox VE 8.2"]
        PVE2["HPE ProLiant DL380 Gen10 Plus — pve02 · 10.10.20.11 — Proxmox VE 8.2"]
    end

    subgraph ZA["Zone A"]
        ACC1["Access Aruba CX 6100 24G PoU 370W #1 — acc-sw-a1 · 10.10.10.11"]
    end
    subgraph ZB["Zone B"]
        ACC2["Access Aruba CX 6100 24G PoU 370W #2 — acc-sw-b1 · 10.10.10.12"]
    end
    subgraph ZC["Zone C"]
        ACC3["Access Aruba CX 6100 24G PoU 370W #3 — acc-sw-c1 · 10.10.10.13"]
    end

    POSTES["Postes filaires — VLAN 30 USERS"]
    AP["Point d'accès WiFi — ap-corpo-01 · réservé 10.10.10.31 — CORP-SSID / GUEST-SSID"]

    ORANGE -->|"Fibre — lien principal"| FW
    TELMA -->|"Fibre — lien secondaire"| FW
    STAR -->|"Satellite — standby pur"| FW
    FW ---|"Liaison L3 · 10.10.10.254"| CORE
    CORE ---|"Patch — trunk 802.1Q"| PP
    PP --- ACC1
    PP --- ACC2
    PP --- ACC3
    CORE ---|"SFP+ 10G"| NAS
    CORE ---|"SFP+ 10G"| PVE1
    CORE ---|"SFP+ 10G"| PVE2
    ACC1 --- POSTES
    ACC2 --- POSTES
    ACC3 --- POSTES
    ACC1 -.->|"PoE 802.3af/at"| AP
```

## topologie-logique.mmd

Segmentation VLAN 10 à 90 avec sous-réseaux, passerelles SVI et placement des hôtes/VM dans chaque VLAN.

```mermaid
%% Topologie logique — segmentation VLAN — source de vérité : docs/00-architecture-reference.md
%% Passerelle de chaque VLAN : SVI sur le Core Aruba.
flowchart TD
    CORE["Core Aruba CX 6300 VSF — routage inter-VLAN — core-sw-01 · 10.10.10.2"]
    FW["WatchGuard Firebox M270 — périmètre, NAT, publication DMZ"]

    subgraph V10["VLAN 10 MGMT — 10.10.10.0/24 · gw 10.10.10.1"]
        M1["core-sw-01 · 10.10.10.2"]
        M2["acc-sw-a1/b1/c1 · 10.10.10.11 à 10.10.10.13"]
        M3["Interco WatchGuard · 10.10.10.254"]
        M4["ap-corpo-01 · réservé 10.10.10.31"]
    end

    subgraph V15["VLAN 15 CLUSTER — 10.10.15.0/24 · gw 10.10.15.1 · MTU 9000"]
        C1["corosync pve01 · 10.10.15.10"]
        C2["corosync pve02 · 10.10.15.11"]
        C3["Stockage nas-nfs — NFS Proxmox"]
    end

    subgraph V20["VLAN 20 SERVERS — 10.10.20.0/24 · gw 10.10.20.1"]
        S1["pve01 · 10.10.20.10 — pve02 · 10.10.20.11"]
        S2["DC01 · 10.10.20.101 — DC02 · 10.10.20.102"]
        S3["FILE01 · 10.10.20.110 — WSUS01 · 10.10.20.111"]
    end

    subgraph V30["VLAN 30 USERS — 10.10.30.0/24 · gw 10.10.30.1"]
        U1["Postes filaires — DHCP 10.10.30.100–200 · bail 8h"]
    end

    subgraph V40["VLAN 40 WIFI — 10.10.40.0/22 · gw 10.10.40.1"]
        W1["Clients corporate CORP-SSID — 802.1X · DHCP 10.10.40.100 à 10.10.43.200"]
    end

    subgraph V50["VLAN 50 BACKUP — 10.10.50.0/24 · gw 10.10.50.1 · MTU 9000"]
        B1["PBS01 · 10.10.50.10 — Proxmox Backup Server 3.1"]
        B2["nas01 · 10.10.50.20 — Synology RS1221+"]
    end

    subgraph V60["VLAN 60 MONITORING — 10.10.60.0/24 · gw 10.10.60.1"]
        O1["mon-prom-01 · 10.10.60.10 — mon-graf-01 · 10.10.60.11"]
        O2["mon-alert-01 · 10.10.60.12 — mon-zbx-01 · 10.10.60.20"]
    end

    subgraph V70["VLAN 70 GUEST — 10.10.70.0/22 · gw 10.10.70.1"]
        G1["Invités WiFi GUEST-SSID — DHCP 10.10.70.100 à 10.10.71.200 · bail 4h"]
    end

    subgraph V80["VLAN 80 APPS — 10.10.80.0/24 · gw 10.10.80.1"]
        A1["APP01 · 10.10.80.101 — GLPI01 · 10.10.80.110"]
    end

    subgraph V90["VLAN 90 DMZ — 10.10.90.0/28 · gw 10.10.90.1"]
        D1["dmz-rp-01 · 10.10.90.10 — reverse proxy Nginx"]
        D2["WatchGuard interface interne · 10.10.90.2"]
    end

    CORE -->|"SVI"| V10
    CORE -->|"SVI"| V15
    CORE -->|"SVI"| V20
    CORE -->|"SVI"| V30
    CORE -->|"SVI"| V40
    CORE -->|"SVI"| V50
    CORE -->|"SVI"| V60
    CORE -->|"SVI · isolation no inter-STA"| V70
    CORE -->|"SVI"| V80
    CORE -->|"SVI"| V90
    FW ---|"Défaut 0.0.0.0/0 via 10.10.10.254"| CORE
    V70 -.->|"Internet seul — pas de transit LAN"| FW
    FW ---|"Publication 443"| D1
    D1 -->|"Proxy inverse"| A1
```

## architecture-proxmox.mmd

Cluster Proxmox VE 8.2 pve01/pve02 : bridges vmbr0/vmbr1, stockage local-zfs + nas-nfs + datastore PBS, affectation des VMID 101 à 501.

```mermaid
%% Architecture Proxmox VE 8.2 — cluster pve01/pve02 — source de vérité : docs/00-architecture-reference.md
flowchart TD
    subgraph CLU["Cluster Proxmox VE 8.2 — corosync sur VLAN 15 CLUSTER · MTU 9000"]
        direction TB
        subgraph H1["pve01.example.local — 10.10.20.10 · corosync 10.10.15.10"]
            direction TB
            BR0A["vmbr0 — LAN VM · VLAN étiquetés"]
            BR1A["vmbr1 — cluster + stockage · VLAN 15"]
            V101["101 · DC01 · 10.10.20.101 · VLAN 20"]
            V110["110 · FILE01 · 10.10.20.110 · VLAN 20"]
            V111["111 · WSUS01 · 10.10.20.111 · VLAN 20"]
            V301["301 · PBS01 · 10.10.50.10 · VLAN 50"]
            V410["410 · MON-ZBX · 10.10.60.20 · VLAN 60"]
            ZFS1["local-zfs pve01 — RAID1 local HPE"]
        end
        subgraph H2["pve02.example.local — 10.10.20.11 · corosync 10.10.15.11"]
            direction TB
            BR0B["vmbr0 — LAN VM · VLAN étiquetés"]
            BR1B["vmbr1 — cluster + stockage · VLAN 15"]
            V102["102 · DC02 · 10.10.20.102 · VLAN 20"]
            V201["201 · APP01 · 10.10.80.101 · VLAN 80"]
            V210["210 · GLPI01 · 10.10.80.110 · VLAN 80"]
            V401["401 · MON-PROM · 10.10.60.10 · VLAN 60"]
            V402["402 · MON-GRAF · 10.10.60.11 · VLAN 60"]
            V403["403 · MON-ALERT · 10.10.60.12 · VLAN 60"]
            V501["501 · DMZ-RP · 10.10.90.10 · VLAN 90"]
            ZFS2["local-zfs pve02 — RAID1 local HPE"]
        end
    end

    NFS["nas-nfs — datastore NFS via VLAN 15 · MTU 9000"]
    NAS["nas01 — Synology RS1221+ · 10.10.50.20 · DSM 7.2"]
    PBD["PBS 3.1 — datastore de sauvegarde sur NAS · prune-after 30 j"]

    V101 -->|" VLAN 20 "| BR0A
    V110 -->|" VLAN 20 "| BR0A
    V111 -->|" VLAN 20 "| BR0A
    V301 -->|" VLAN 50 "| BR0A
    V410 -->|" VLAN 60 "| BR0A
    V102 -->|" VLAN 20 "| BR0B
    V201 -->|" VLAN 80 "| BR0B
    V210 -->|" VLAN 80 "| BR0B
    V401 -->|" VLAN 60 "| BR0B
    V402 -->|" VLAN 60 "| BR0B
    V403 -->|" VLAN 60 "| BR0B
    V501 -->|" VLAN 90 "| BR0B

    BR1A ---|"corosync + stockage"| BR1B
    BR1A --- NFS
    BR1B --- NFS
    NFS --- NAS
    BR0A -.-> ZFS1
    BR0B -.-> ZFS2
    V301 -->|"sauvegardes incrémentales chiffrées"| PBD
    PBD -->|"montage NFS"| NAS
```

## flux-lan-wan.mmd

Flux LAN→WAN : poste → accès → core puis serveurs/apps/GLPI, et core → WatchGuard → FAI → Internet.

```mermaid
%% Flux LAN → WAN — poste, accès, core, ressources, firewall, FAI
%% Source de vérité : docs/00-architecture-reference.md
flowchart LR
    POSTE["Poste utilisateur — VLAN 30 USERS · DHCP 10.10.30.100–200"]
    WIFI["Client WiFi — VLAN 40 WIFI · CORP-SSID 802.1X"]
    ACC["Switch Access Aruba CX 6100 — acc-sw-a1/b1/c1 — access VLAN 30 · trunk 802.1Q"]
    CORE["Core Aruba CX 6300 VSF — core-sw-01 — passerelle par défaut de tous les VLAN"]
    SRV["Serveurs — VLAN 20 · 10.10.20.0/24 — DC01 · DC02 · FILE01 · WSUS01 · pve01/02"]
    APP["Apps — VLAN 80 · 10.10.80.0/24 — APP01 10.10.80.101 · GLPI01 10.10.80.110"]
    MON["Monitoring — VLAN 60 · 10.10.60.0/24 — Prometheus · Grafana · Zabbix"]
    FW["WatchGuard Firebox M270 — SPI · NAT/PAT · PBR — interco 10.10.10.254"]
    WAN["FAI — Orange principal · Telma secondaire · Starlink standby — PUBLIC_IP_REDACTED"]
    INET["Internet"]

    POSTE --> ACC
    WIFI --> ACC
    ACC -->|"trunk — routage SVI"| CORE
    CORE -->|"10.10.20.0/24"| SRV
    CORE -->|"10.10.80.0/24"| APP
    CORE -->|"10.10.60.0/24"| MON
    CORE -->|"route 0.0.0.0/0 via 10.10.10.254"| FW
    FW -->|"PBR par application — sondes Gateway Dependency"| WAN
    WAN --> INET
```

## flux-utilisateur.mmd

Séquence utilisateur : DHCP/ouverture de session, authentification AD, DNS, SMB vers FILE01, HTTP vers l'app métier.

```mermaid
%% Flux utilisateur — ouverture de session, AD, DNS, SMB, application
%% Source de vérité : docs/00-architecture-reference.md ( DHCP/DNS : DC01/DC02 )
sequenceDiagram
    participant P as Poste — VLAN 30 (10.10.30.100–200)
    participant A as Switch Access CX 6100
    participant C as Core CX 6300 VSF (10.10.30.1)
    participant D as DC01 — AD/DNS/DHCP (10.10.20.101)
    participant F as FILE01 (10.10.20.110)
    participant G as APP01 (10.10.80.101)

    P->>A: DHCP DISCOVER — access VLAN 30
    A->>C: Trunk 802.1Q vers le Core
    C->>D: Relai ip helper-address (10.10.20.101, 10.10.20.102)
    D-->>P: Bail 8h — IP pool, passerelle 10.10.30.1, DNS 10.10.20.101/102
    P->>D: Ouverture de session — Kerberos / LDAP via routage VLAN 30 → 20
    D-->>P: Authentification AD validée + GPO appliquées
    P->>D: Requête DNS — file01.example.local · app01.example.local
    D-->>P: Réponse DNS (zone AD-integrated example.local)
    P->>F: SMB — montage des partages (RBAC groups-based access)
    F-->>P: Lecture / écriture fichiers autorisées
    P->>G: HTTP — accès application métier (VLAN 30 → 80)
    G-->>P: Réponse applicative
```

## flux-internet.mmd

Séquence Internet : sortants NAT/PAT + failover 3 FAI, entrants GLPI publié via reverse proxy DMZ.

```mermaid
%% Flux Internet — sortants (NAT/PAT + failover) et entrants (GLPI publié via DMZ)
%% Source de vérité : docs/00-architecture-reference.md + docs/networking.md
sequenceDiagram
    participant P as Poste — VLAN 30
    participant C as Core CX 6300 VSF
    participant FW as WatchGuard M270 — 10.10.90.2 / 10.10.10.254
    participant FAI as FAI — Orange ou Telma (PUBLIC_IP_REDACTED)
    participant I as Internet
    participant RP as dmz-rp-01 — VLAN 90 · 10.10.90.10
    participant GL as GLPI01 — VLAN 80 · 10.10.80.110

    Note over P,I: Flux sortant LAN vers Internet
    P->>C: Paquet destination Internet — routage SVI 10.10.30.1
    C->>FW: Route 0.0.0.0/0 via 10.10.10.254
    FW->>FAI: NAT/PAT depuis PUBLIC_IP_REDACTED — PBR par application
    FAI->>I: Sortie Internet
    Note over FW: Sonde Gateway Dependency 10 s · 3 échecs = bascule — Starlink activé si Orange ET Telma down (CGNAT sortant)

    Note over I,GL: Flux entrant — GLPI publié (règle : rien sans reverse proxy DMZ)
    I->>FW: HTTPS 443 vers PUBLIC_IP_REDACTED
    FW->>RP: Published Server — DNAT vers DMZ VLAN 90 uniquement
    RP->>GL: Proxy inverse HTTPS vers GLPI01 (interdit côté WAN en direct)
    GL-->>I: Réponse via dmz-rp-01 puis WatchGuard
```

## backup.mmd

Chaîne de sauvegarde 3-2-1 : VM prod → PBS01 → NAS Synology → réplication chiffrée hors-site, avec rétention GFS.

```mermaid
%% Sauvegarde 3-2-1 — PBS, NAS, hors-site — source : docs/00-architecture-reference.md §7 + docs/backup.md
flowchart LR
    VM["Copie 1 — Production — pve01 / pve02 · local-zfs RAID1"]
    PBS["Copie 2 — PBS01 · 10.10.50.10 — Proxmox Backup Server 3.1 · VLAN 50 · MTU 9000"]
    NAS["nas01 — Synology RS1221+ · 10.10.50.20 — datastore PBS via NFS · Btrfs · retention lock immutable"]
    OFF["Copie 3 — Hors-site — stockage objet distant · réplication chiffrée · air-gap logique"]

    WIN["Windows — AD System State · FILE01 · WSUS01 — Veeam Agent / wbadmin"]
    CFG["Config réseau — Aruba · WatchGuard · MikroTik · NAS — dépôt privé versionné"]

    VM -->|"Sauvegarde full + incrémentale chiffrée + dédup — RPO Tier 0 : 1 h"| PBS
    WIN -->|"Agent Windows vers datastore NAS"| NAS
    CFG -->|"Archive 90 versions"| NAS
    PBS -->|"Datastore monté en NFS — prune-after 30 jours"| NAS
    NAS -->|"Snapshot Replication / Hyper Backup — chiffré, immuable"| OFF

    subgraph RET["Rétention (docs/backup.md)"]
        R1["Incrémental — 7 jours glissants"]
        R2["Full hebdo — 4 semaines"]
        R3["Mensuel — 12 mois"]
        R4["Annuel / archivage — 5 ans"]
    end
    NAS --- RET
```

## monitoring.mmd

Pile de supervision : exporters → Prometheus → Grafana/Alertmanager → notifications, Zabbix et SNMP v3 vers les équipements réseau.

```mermaid
%% Pile de supervision — Prometheus / Grafana / Alertmanager / Zabbix — source : docs/monitoring.md
flowchart LR
    subgraph SRC["Sources de métriques"]
        NET["Réseau — Aruba CX · WatchGuard · MikroTik · AP — SNMP v3 authPriv"]
        LNX["Linux — node_exporter — APP01 · GLPI01 · DMZ-RP · MON"]
        WIN["Windows — windows_exporter — DC01 · DC02 · FILE01 · WSUS01"]
        PVE["Hyperviseur — pve-exporter — pve01 · pve02 via API Proxmox"]
        SVC["Services — blackbox_exporter — HTTP · TCP · DNS · ICMP"]
    end

    SNMPE["snmp_exporter"]
    PROM["Prometheus — mon-prom-01 · 10.10.60.10 — VLAN 60"]
    GRAF["Grafana — mon-graf-01 · 10.10.60.11 — dashboards périmètre · réseau · Proxmox · services · backup"]
    ALERT["Alertmanager — mon-alert-01 · 10.10.60.12 — group_by · inhibition · silences"]
    ZBX["Zabbix 6.0 LTS — mon-zbx-01 · 10.10.60.20 — triggers · maps"]
    NOTIF["Notifications — e-mail IT · webhook WEBHOOK_REDACTED"]
    GLPI["GLPI01 · 10.10.80.110 — incident → ticket ITIL"]

    NET -->|"SNMP v3"| SNMPE
    SNMPE --> PROM
    LNX --> PROM
    WIN --> PROM
    PVE --> PROM
    SVC --> PROM
    PROM -->|"requêtes"| GRAF
    PROM -->|"règles info / warning / critical"| ALERT
    ALERT --> NOTIF
    ALERT -->|"ticket auto sur incident"| GLPI
    NET -->|"SNMP v3"| ZBX
    ZBX -.->|"escalade ITIL"| GLPI
```
