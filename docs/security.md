# Sécurité — durcissement & conformité

> Document complémentaire à [`networking.md`](networking.md#9-sécurité-réseau).
> Toutes les valeurs d'authentification sont anonymisées (`<REDACTED>`, `CHANGEME****`).

## 1. Modèle de menaces (simplifié)

| Surface | Menace principale | Contre-mesure |
|---------|-------------------|---------------|
| WAN / Internet | Scan, brute force, botnet | SPI, GeoIP, blocklists, rate-limit, pas de services publiés directs |
| Postes | Malware, mouvement latéral | EDR/AV, GPO durcies, segmentation VLAN, LAPS |
| WiFi | Rogue AP, écoute | 802.1X WPA3-Enterprise, isolation client, NPM |
| Identités | Vol de creds, escalade | MFA, least-privilege, PAM, journalisation |
| Sauvegarde | Rançongadie | immutabilité Btrfs, chiffrement, hors-site, tests de restore |
| Hyperviseur | Accès admin | 2FA, tokens à scope, hardening Proxmox |

## 2. Défense en profondeur

```
Internet ──► [WatchGuard SPI+proxy] ──► [DMZ reverse proxy] ──► [Apps] ──► [Data]
                  │                        isolation LAN              ACL
             3 FAI + failover        pas de WAN direct VM       AD/MFA/LAPS
```

## 3. Durcissement par couche

### Réseau (Aruba / WatchGuard)
- Désactivation des services inutiles (HTTP mgmt, CDP excessif, Telnet).
- SSH v2 uniquement, ACL mgmt VLAN 10 limitée aux postes admin.
- SNMP **v3** `authPriv` (AES/SHA), pas de community string claire.
- DHCP snooping + DAI + IP Source Guard sur VLAN 30/40, BPDU/Root guard.
- WatchGuard : TLS inspection sortante, app signatures, reputation, logs ≥12 mois.

### Système (Windows / Linux)
- **GPO** : base CIS Benchmark (niveau 1), LAPS, Windows Firewall par défaut allow-list,
  NTP vers DC01, désactivation SMBv1, audit ADV.
- **WSUS** : patchs approuvés après anneau de test → déploiement piloté.
- Linux (Debian 12) : `unattended-upgrades`, fail2ban sur GLPI/reverse proxy, SSH clés,
  AppArmor, partition /var/log separate.

### Hyperviseur (Proxmox)
- 2FA TOTP obligatoire sur l'API/Web UI, tokens API à scope minimal (backups only).
- Pas d'accès SSH root direct ; jump host dans VLAN 10.
- Cluster corosync isolé sur VLAN 15 (MTU 9000), pas d'exposition WAN.
- Sauvegarde de `/etc/pve` et config, durcissement firewall hôte (`/etc/pve/firewall`).

### Identité & accès
- **MFA** sur comptes privilégiés et accès distant (RDNA/VPN via WatchGuard).
- **LAPS** pour les mots de passe locaux, rotation automatique.
- RBAC : accès fichiers par groupe AD, pas d'accès direct FILE01 hors AD.
- Séparation des tâches : admin réseau ≠ admin domaine ≠ opérateur backup.
- Revue trimestrielle des droits et des comptes dormants.

### Sauvegarde
- Chiffrement au repos (Btrfs/`-encryption` PBS) et en transit (TLS).
- Copie **immutable** (WORM/retention lock Synology) contre la rançongadie.
- Une copie **hors-site** testée.

## 4. Matrice des flux autorisés (défaut = deny)

| Source ↓ / Dest → | MGMT 10 | SERVERS 20 | USERS 30 | APPS 80 | GUEST 70 | BACKUP 50 | MONIT 60 | Internet |
|---|---|---|---|---|---|---|---|---|
| **MGMT 10** | — | SSH/RDP/WMI | — | SSH | — | SSH | UI | maj |
| **SERVERS 20** | SNMP← | — | GPO← | AD/LDAP/DNS | DNS | →backup | ←scrape | NTP/WSUS |
| **USERS 30** | — | AD/DNS/SMB | — | App/GLPI HTTP | — | — | — | Oui |
| **WIFI 40** | = USERS | | | | | | | |
| **GUEST 70** | ✗ | ✗ | ✗ | ✗ | — (isol.) | ✗ | ✗ | Oui seul |
| **APPS 80** | — | AD/DNS | ←HTTP | — | — | →backup | ←scrape | limit |
| **MONIT 60** | SNMP/SSH | WMI | — | HTTP probe | — | API PBS | — | NTP |

Légende : `←` = l'autre côté initie vers la destination ; `✗` = bloqué ; `—` = N/A.

## 5. Journalisation & détection

- Collecte syslog unifiée (VLAN 60) : équipements réseau, FW, hôtes, AD security events.
- Rétention 12 mois, horodatage NTP via DC01.
- Corrélations/alertes : échecs d'authentification, privélèges, échecs backup, bascule FAI,
  cert expiration, port flapping.
- GLPI = traçabilité des incidents/interventions (lien ticket ↔ événement).

## 6. Checklist de mise en production

- [ ] Tous les `<REDACTED>` remplacés par des secrets en coffre (hors dépôt).
- [ ] SNMP v1/v2c désactivés partout.
- [ ] MFA actif sur admin domaine + hyperviseur + FW.
- [ ] GPO CIS niveau 1 liées et appliquées (gpresult /r).
- [ ] Backups Tier0 testés en restauration (voir `automation/backup/restore-drill.sh`).
- [ ] Failover 3 FAI testé (simu de panne).
- [ ] Syslog reçu et rétention vérifiée.
- [ ] Revue des droits RBAC signée.

## 7. Anonymisation (dépôt public)

Ce dépôt est un **portfolio**. Avant tout push :
- IPs publiques → `PUBLIC_IP_REDACTED`, domaines → `example.local`.
- Mots de passe / tokens / community strings / certificats → placeholders.
- Aucune donnée client, aucun nom réel, aucune IP routable interne.
- Voir le `.gitignore` (exclure `.env`, clés, captures non floutées).
