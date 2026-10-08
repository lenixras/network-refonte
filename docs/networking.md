# Réseau & Sécurité — conception

> Adresses, VLAN et hôtes : voir [`00-architecture-reference.md`](00-architecture-reference.md).

## 1. Couches et rôles

```
Postes / AP ──► Switch Access Aruba ──► Core Aruba (L3) ──► WatchGuard ──► FAI ──► Internet
   (couche 2)        (trunk/access)        (routage inter-VLAN)  (périmètre/NAT/failover)
```

- **Core Aruba CX 6300 (VSF)** : passerelle par défaut de tous les VLAN (SVI), routage
  inter-VLAN, QoS DSCP, uplink 2×10G vers le WatchGuard et 3× uplink vers les accès.
- **Access Aruba CX 6100** : ports d'accès (VLAN 30), PoE pour les AP WiFi, trunk 802.1Q
  monté vers le Core, storm-control et port-security.
- **WatchGuard Firebox M270** : terminaison des 3 WAN, stateful inspection, NAT, proxy
  applicatif, failover.

## 2. VLAN & segmentation

| VLAN | Nom | Préfixe | Trust | Vers Internet |
|------|-----|---------|-------|----------------|
| 10 | MGMT | `10.10.10.0/24` | Administrateurs uniquement | Non (sortie contrôlée maj) |
| 15 | CLUSTER | `10.10.15.0/24` | Proxmox uniquement | Non |
| 20 | SERVERS | `10.10.20.0/24` | Serveurs | Limité (WSUS, NTP, updates) |
| 30 | USERS | `10.10.30.0/24` | Postes | Oui (contrôlé FW) |
| 40 | WIFI | `10.10.40.0/22` | Postes nomades | Oui |
| 50 | BACKUP | `10.10.50.0/24` | PBS/NAS | Non |
| 60 | MONITORING | `10.10.60.0/24` | Outils de supervision | Limité (NTP, mises à jour) |
| 70 | GUEST | `10.10.70.0/22` | Non fiable | **Oui uniquement** |
| 80 | APPS | `10.10.80.0/24` | Métier + GLPI | Limité |
| 90 | DMZ | `10.10.90.0/28` | Semi-fiable | Publie reverse proxy |

Principes : **least-privilege**, défaut **deny**, isolation GUEST par client (no inter-STA),
et pas de transit GUEST→LAN.

## 3. Routage inter-VLAN

Tout le L3 est sur le Core (SVI). Extrait (`configs/aruba/core-switch.cfg`) :

```
vlan 30
 name USERS
interface vlan 30
 ip address 10.10.30.1/24
 no shutdown
ip default-gateway-style: SVI 10.10.10.1 → route 0.0.0.0/0 via 10.10.10.254 (WatchGuard)
```

Le Core relaie le DHCP (`ip helper-address 10.10.20.101 10.10.20.102`) vers les DC pour
les VLAN 30/40/70.

## 4. Trunks / Access

| Lien | Type | VLAN transportés |
|------|------|------------------|
| Access→Core | Trunk 802.1Q | 10,20,30,40,60 |
| AP→Access | Trunk | natif 30 + tag 40 |
| Core→WatchGuard | Trunk/routé | 10 (L3 interco) + DMZ |
| Postes→Access | Access | 30 |

LACP (`interface lag 1`) entre les 2 membres VSF du Core et pour les uplinks critiques.

## 5. DHCP / DNS

- **DNS** : `example.local` hébergé par DC01/DC02 (AD-integrated, zone reversal
  `10.10.in-addr.arpa`). Forwarders sortants gérés par le WatchGuard.
- **DHCP** : scopes Windows (DC01/DC02) en résilient 50/50, options 003 (passerelle SVI),
  006 (DNS), 015 (domaine `example.local`), 043 (AP Aruba, option vendor).
- **GUEST** : DHCP local limité, DNS = WatchGuard (résolution Internet seule).

## 6. NAT & publication de services

| Type | Interne | Externe (anonymisé) | Service |
|------|---------|---------------------|---------|
| PAT sortant | tout le LAN | `PUBLIC_IP_REDACTED` (Orange) | Internet |
| Published Server | `10.10.90.10` (reverse proxy DMZ) | `PUBLIC_IP_REDACTED` :443 | GLPI/HTTPS (via DMZ uniquement) |
| NAPT | aucune VM côté WAN directe | — | **Règle : rien n'est publié sans passer par le DMZ reverse proxy** |

## 7. Failover et gestion des 3 FAI

Mode **active / active / standby** :

| FAI | État | Weight / rôle | Sonde (keepalive) |
|-----|------|---------------|-------------------|
| Orange FH | **Active (principal)** | 60% du trafic, PBR par app critique | 208.67.222.222 / gateway FAI |
| Telma | **Active (secondaire)** | 40%, failover immédiat si Orange down | 1.1.1.1 / gateway FAI |
| Starlink | **Standby** | ACTIVÉE seulement si Orange ET Telma down | 8.8.8.8 (CGNAT, non publié) |

- **Détection** : sondes Gateway Dependency toutes les 10 s, 3 échecs → bascule.
- **Retour (failback)** : Stabilisation 120 s avant retour sur Orange pour éviter le ping-pong.
- **Glissement de session** : TCP sticky / connexion longue conservées côté applicatif.
- **Starlink** : en secours uniquement à cause de la latence (~40–120 ms) et du CGNAT
  sortant (pas d'IP publique stable pour les services publiés).
- Voir `configs/watchguard/wan-failover.txt` et l'animation
  [`diagrams/animated/failover-3-fai.html`](../diagrams/animated/failover-3-fai.html).

## 8. QoS

- Marquage **DSCP** à l'entrée (Core) : EF (voice) si VoIP, AF41 (app métier),
  AF21 (GLPI/critique), best-effort (users), bulk (backup), CS6/CS7 (mgmt/route).
- **Queue** sur WatchGuard : shaping par FAI, priorisation des flux métier et de la
  supervision ; limitation du GUEST.
- Backup/CLUSTER isolés en VLAN avec MTU 9000 pour ne pas saturer USERS.

## 9. Sécurité réseau

- **Ports** : port-security, BPDU guard, root guard, DHCP snooping (VLAN 30/40),
  Dynamic ARP Inspection, storm control.
- **Périmètre** : SPI WatchGuard, GeoIP/reputation, TLS inspection sur le HTTP(s) sortant,
  blocklists, anti-botnet.
- **WiFi** : WPA2/WPA3-Enterprise **802.1X + RADIUS (NPS sur DC)**, GUEST en WPA3-PSI/open
  + portail captif, **client isolation** et pas de routage GUEST→LAN.
- **MGMT** : SSHv2, ACL d'accès admin restreinte à la VLAN 10 depuis hôtes fixes, pas de
  TelHTTP/HTTP, SNMP **v3 authPriv** (pas de v1/v2c).

## 10. Journalisation

- Syslog centralisé : Core, Access, WatchGuard, AP, NAS → serveur de logs (VLAN 60),
  rétention ≥ 12 mois.
- Windows : Security/ForwardedEvents → collecte (audit logon, privélèges, GPO).
- Proxmox : `/var/log/pve*`, auth.log, API audit (`/etc/pve/access.log`).
- GLPI : suivi des tickets et des interventions IT.

## 11. Gestion des accès & privilèges

- **AD** : groups-based access, RBAC sur les partages FILE01, **LAPS** pour les mots de
  passe locaux, MFA sur les comptes admin et l'accès à distance.
- **Proxmox** : rôles `PVEAdmin`/`Operator` limités, 2FA (TOTP), tokens API nommés à
  scope minimal, pas d'accès root direct au réseau (jump host en MGMT).
- **WatchGuard** : comptes distincts admin/auditeur, 2FA, change control.
- Séparation des environnements et revue périodique des droits.
