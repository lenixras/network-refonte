# Fonctionnement en production — flux de bout en bout

Ce document décrit les **flux réels** d'une journée d'exploitation, cohérents avec
[`00-architecture-reference.md`](00-architecture-reference.md) et la matrice de flux de
[`security.md`](security.md#4-matrice-des-flux-autorisés-défaut--deny).

## 1. Flux canonique

```
Poste Windows
    ↓  (access VLAN 30)
Switch Access Aruba  ──(trunk 802.1Q)──
    ↓
Core Aruba (SVI VLAN 30, 10.10.30.1)
    ├──► AD / DNS / File Server      (10.10.20.101/102/110)
    ├──► Application métier          (10.10.80.101)
    ├──► GLPI                        (10.10.80.110)
    └──► WatchGuard (10.10.10.254)
              ↓  NAT + QoS + failover
        Orange / Telma / Starlink  (PUBLIC_IP_REDACTED)
              ↓
           Internet
```

## 2. Ouverture de session d'un poste (auth AD + DNS + GPO + fichier)

1. **DHCP** : le poste obtient une IP en `10.10.30.0/24` (relay Core → DC01/02),
   options 003 = `10.10.30.1`, 006 = `10.10.20.101/102`, 015 = `example.local`.
2. **DNS** : le poste interroge DC01 (ou DC02) pour `_ldap._tcp.dc._msdcs.example.local`
   (SRV) → localise un contrôleur de domaine.
3. **Authentification** : logon de domaine **Kerberos** vers `DC01/DC02` ; si MFA requis
   pour les comptes privilégiés, challenge complémentaire.
4. **GPO** : le poste récupère ses stratégies (LAPS, AppLocker, lecteur réseau, WSUS,
   firewall, NTP) — application et journalisation.
5. **Lecteur réseau** : mapped drive `\\FILE01.example.local\Utilisateurs` (SMB3,
   autorisation par **groupe AD**, RBAC).
6. **NTP** : horloge synchronisée sur DC01 → cohérence Kerberos (tolérance 5 min).

> Animation : [`diagrams/animated/poste-ad-dns.html`](../diagrams/animated/poste-ad-dns.html).

## 3. Accès à l'application métier

- Poste (VLAN 30) → **APP01** (`10.10.80.101`) HTTP/S : le WatchGuard/Core n'autorise
  USERS/WIFI → APPS que sur les ports applicatifs (flux métier).
- **QoS** : le traffic métier est marqué **AF41**, priorisé dans les queues WAN et LAN.
- **Auth** : SSO/LDAP vers AD si l'app le supporte, sinon comptes applicatifs AD.

## 4. Accès à GLPI (IT)

- Interne : `http://10.10.80.110` (VLAN 30/40 → APPS), authentification **LDAP/AD**.
- Externe (techniciens mobiles) : via **reverse proxy DMZ** `10.10.90.10` derrière le
  WatchGuard (HTTPS 443, certificat TLS), **jamais** de exposition directe de la VM.
- Cycle de vie : utilisateur ouvre un ticket → triage → incident → intervention →
  clôture → SLA mesuré.
  Animation : [`diagrams/animated/user-glpi-ticket.html`](../diagrams/animated/user-glpi-ticket.html).

## 5. Accès Internet

- USERS/WIFI → WatchGuard → **NAT/PAT** vers l'IP Orange (primaire) `PUBLIC_IP_REDACTED`.
- **GUEST** : NAT Internet **seul**, aucune route vers le LAN, DNS limité, client isolation.
- **Failover** : si Orange down → Telma (basculé), si les deux → Starlink.
  Animation : [`diagrams/animated/failover-3-fai.html`](../diagrams/animated/failover-3-fai.html)
  et [`diagrams/animated/poste-switch-core-fw-internet.html`](../diagrams/animated/poste-switch-core-fw-internet.html).
- **TLS inspection** + filtrage applicatif + blocklists sur le sortant.

## 6. WSUS & mises à jour

- Postes/servers → **WSUS01** (`10.10.20.111`) via GPO (intranet), pas de Windows Update
  direct depuis Internet → économie de bande passante WAN.
- WSUS01 se synchronise upstream selon un planning (contrôlé par le FW, anneau Test puis
  Production).

## 7. Sauvegarde (nuit + continu)

- Proxmox → **PBS01** (VMs, incrémental chiffré) → datastore sur **NAS** →
  **Snapshot Replication** chiffré/immuable vers **hors-site**.
- FILE01/AD System State via Veeam/wbadmin → NAS.
- Test de restauration mensuel consigné en ticket GLPI.
  Schéma : [`diagrams/backup.mmd`](../diagrams/backup.mmd) ·
  animation [`diagrams/animated/vm-backup-nas.html`](../diagrams/animated/vm-backup-nas.html).

## 8. Monitoring & alerte

- Prometheus scrape le plane (SNMP/exporters/blackbox) → Grafana (dashboards) +
  Alertmanager (e-mail/webhook) → **incident GLPI** → intervention.
  Schéma : [`diagrams/monitoring.mmd`](../diagrams/monitoring.mmd) ·
  animation [`diagrams/animated/monitoring-alert.html`](../diagrams/animated/monitoring-alert.html).

## 9. Matrice des flux (résumé)

| Flux | Source → Dest | Protocole | Autorisé par | QoS |
|------|---------------|-----------|--------------|-----|
| Auth | USERS → SERVERS | Kerberos/LDAP 88/389/636 | FW ACL + AD | AF21 |
| Résolution | USERS → DNS 53 | DNS | FW ACL | EF/AF |
| Fichier | USERS → FILE01 | SMB 445 | RBAC AD + ACL | AF21 |
| Métier | USERS → APP01 | HTTP/S | FW ACL | **AF41** |
| IT | USERS → GLPI01 | HTTP/S 443 (via DMZ) | FW + MFA | AF21 |
| Internet | USERS → WAN | NAT 80/443 | FW + TLS insp | Best-effort |
| Guest | GUEST → Internet | NAT | **FW, no LAN** | Limité |
| Backup | SERVERS → BACKUP | PBS/SMB/NFS | VLAN 50 isolé | Bulk |
| Monitoring | MONIT → tout | SNMP/scrape | read-only | Best-effort |

> `EF` = voice/expedite, `AFxx` = assured-forward, `bulk` = backup, détail dans
> [`networking.md`](networking.md#8-qos).

## 10. Rôles humains

- **Admin réseau** : Aruba/WatchGuard/MikroTik (vlanage, règles FW, failover).
- **Admin système** : AD/GPO/WSUS/File/Proxmox (RBAC, patching, capacity).
- **Opérateur backup** : jobs, réplication, restore drill (compte distinct).
- **Support IT (GLPI)** : triage des tickets/incidents, interventions, SLA.
- Séparation des tâches + revue trimestrielle des droits (voir
  [`security.md`](security.md#11-gestion-des-accès--privilèges)).
