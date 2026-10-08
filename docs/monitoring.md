# Monitoring & observabilité

## 1. Objectif

Superviser **réseau, serveurs, hyperviseur, VMs, services et sauvegardes**, avec alerting
proactif et tableaux de bord. Deux briques complémentaires :

- **Prometheus + Grafana + Alertmanager** : métriques temps réel, dashboards, alerting.
- **Zabbix 6.0 LTS** : règles réseau/système historiques + templates équipements.
- **GLPI** : volet ITIL (l'alerte devient ticket/incident, puis intervention).

## 2. Architecture de supervision

```
[SNMP v3] Aruba/WatchGuard/MikroTik/AP  ──► snmp_exporter ┐
[node_exporter] Debian (APP,GLPI,DMZ,MON) ────────────────┤
[windows_exporter] DC01/02,FILE01,WSUS01 ─────────────────┼──► Prometheus ──► Grafana
[pve-exporter] Proxmox API (pve01/02) ───────────────────┤        │              (dashboards)
[blackbox_exporter] HTTP/TCP/DNS/ICMP ────────────────────┘        ▼
                                                          Alertmanager ──► e-mail / webhook
                                                          Zabbix ──► triggers / maps
```

Tout le plane de supervision vit en **VLAN 60 (`10.10.60.0/24`)**, en lecture vers les
cibles (scrape) ; aucun service de monitoring n'est publié côté WAN.

## 3. Ce qui est supervisé

| Couche | Métrique | Source | Seuil d'alerte (exemple) |
|--------|----------|--------|--------------------------|
| **Réseau** | état de port, débit, erreurs CRC, CPU switch | SNMP → snmp_exporter | link down, >80% utilisation |
| **WAN / FAI** | latence, perte, disponibilité FAI, **bascule Orange/Telma/Starlink** | blackbox ICMP + Gateway dependency | 3 échecs → alerte failover |
| **Firewall** | sessions, blocked, HA | SNMP/log | seuil sessions |
| **Serveurs Windows** | CPU/RAM/disk, service AD/DNS/DHCP, temps de réponse LDAP | windows_exporter, blackbox | service stopped, disk>85% |
| **Proxmox** | état nœuds/VMs, stockage, corosync/QDevice, migration | pve-exporter | nœud down, datastore>90% |
| **Linux** | CPU/RAM/disk/load, fail2ban | node_exporter | load> seuil |
| **Services** | GLPI HTTP 200, APP métier, DNS résolution, WSUS sync, NTP | blackbox HTTP/DNS + API | code != 200, délai |
| **Sauvegarde** | succès job PBS, fraicheur réplication off-site, restore drill | API PBS + scripts | job failed, stale > RPO |
| **Certificats** | expiration TLS (reverse proxy, GLPI) | blackbox / script | <30 j |
| **NAS** | RAID, SMART, volume usage, température | SNMP/API DSM | degraded, >85% |

## 4. Alerting

- **Alertmanager** : regroupement (group_by), inhibition, silences, routage par
  criticité/équipe.
- Canaux : **e-mail** IT + **webhook** (Teams/Slack fictifs `WEBHOOK_REDACTED`) +
  **ticket auto GLPI** sur incident.
- Gravités : `info` / `warning` / `critical` ; `critical` = page/escalade.
- Exemples de règles dans
  `automation/monitoring/prometheus/alerts/rules-network.yml` :
  - `NetworkLinkDown`, `HighCPUProxmoxNode`, `BackupJobFailed`, `FAIFailoverTriggered`,
    `GLPIHTTPDown`, `CertificateExpiringSoon`, `ReplicationStale`.

## 5. Tableaux de bord (Grafana, provisioning-as-code)

- **Vue périmètre** : santé 3 FAI, débit WAN, état failover.
- **Vue réseau** : switches/ports, topologie logique.
- **Vue Proxmox/VM** : nœuds, VMs, stockage, migration.
- **Vue services** : GLPI, APP, AD/DNS/DHCP, WSUS.
- **Vue backup** : succès/durée/taille, fraicheur hors-site, dernier restore drill.

## 6. Journalisation & capacity

- Logs centralisés (syslog VLAN 60, rétention 12 mois) — voir
  [`security.md`](security.md#5-journalisation--détection).
- Suivi de capacité : croissance stockage/débit, projection pour les seuils de backup.

## 7. Flux monitoring → alerte → IT
Voir l'animation
[`diagrams/animated/monitoring-alert.html`](../diagrams/animated/monitoring-alert.html)
et le diagramme statique [`diagrams/monitoring.mmd`](../diagrams/monitoring.mmd).

## 8. Automatisation du déploiement
Playbook Ansible : `automation/monitoring/deploy-exporters.yml` (installe les exporters,
pousse la config Prometheus/Grafana). Configs cibles : `automation/monitoring/prometheus/`.
