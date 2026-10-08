# Documentation — index

| Document | Contenu |
|----------|---------|
| [`00-architecture-reference.md`](00-architecture-reference.md) | **Source de vérité** : inventaire, plan VLAN, plan IP, hôtes, VMs, conventions |
| [`networking.md`](networking.md) | VLAN/segmentation, routage inter-VLAN, trunks/access, DHCP/DNS, NAT, **failover 3 FAI**, QoS, sécurité réseau, journalisation |
| [`security.md`](security.md) | Modèle de menaces, defense en profondeur, durcissement, **matrice des flux**, accès/privileges, checklist prod |
| [`virtualization.md`](virtualization.md) | Proxmox VE, cluster, stockage, VMs Windows (AD/DNS/DHCP/GPO/File/WSUS), APP métier, GLPI |
| [`backup.md`](backup.md) | Stratégie **3-2-1**, périmètre, **RPO/RTO** par tier, rétention, outils, **tests de restauration** |
| [`monitoring.md`](monitoring.md) | Prometheus/Grafana/Alertmanager/Zabbix, exporters, métriques, alerting, dashboards |
| [`operations.md`](operations.md) | Flux de production de bout en bout (auth, DNS, fichier, apps, Internet, backup, monitoring) |

## Diagrammes
- Statiques (Mermaid) : [`../diagrams/`](../diagrams/) — topologie physique/logique,
  architecture Proxmox, flux LAN/WAN, backup, monitoring.
- Animés (SVG/CSS/JS, `prefers-reduced-motion`) :
  [`../diagrams/animated/`](../diagrams/animated/) — poste→core→Internet, failover 3 FAI,
  AD/DNS, live migration, VM→backup→NAS, monitoring→alert, ticket GLPI.

## Configurations & automatisation
- Exemples de configs : [`../configs/`](../configs/) (Aruba, WatchGuard, MikroTik,
  Proxmox, Synology, Windows/GPO).
- Scripts : [`../automation/`](../automation/) (inventaire, provisioning, backup,
  monitoring), tous en **dry-run par défaut** et secrets anonymisés.

## Sécurité du dépôt
Toutes les données sensibles sont anonymisées : IPs publiques `PUBLIC_IP_REDACTED`,
domaines `example.local`, secrets `<REDACTED>`. Les captures d'écran doivent être floutées
avant d'être ajoutées à [`../screenshots/`](../screenshots/).
