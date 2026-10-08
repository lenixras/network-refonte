# Virtualisation — Proxmox VE

## 1. Plateforme

- **2× HPE ProLiant DL380 Gen10 Plus** en cluster **Proxmox VE 8.2**.
- Redondance : cluster corosync 2 nœuds + **QDevice** (`pve-qdevice`) sur un tiers léger
  pour éviter le split-brain à 2 nœuds.
- Stockage :
  - `local-zfs` : ZFS RAID1 local (OS + VMs critiques, performant, pas de SPOF disque).
  - `nas-nfs` : NFS depuis le Synology `10.10.50.20` sur VLAN 15/50 (MTU 9000) pour les
    VMs non critiques et l'archive.
  - `pbs` : datastore Proxmox Backup Server (VMID 301) pour les sauvegardes incrémentaires.
- Réseau hôte (`configs/proxmox/pve01-network.yaml`) :
  - `vmbr0` — bridge management/SERVERS, VLAN 20, `10.10.20.10` (pve01) / `.11` (pve02).
  - `vmbr1` — bridge cluster/corosync + stockage, VLAN 15, `10.10.15.10/.11`, MTU 9000.
  - Bond LACP 2×10G vers le Core pour la disponibilité.

## 2. Machines virtuelles

Voir le tableau complet dans [`00-architecture-reference.md`](00-architecture-reference.md#5-machines-virtuelles-proxmox--affectation).

| VMID | Nom | Rôle | OS | Nœud | VLAN |
|------|-----|------|----|------|------|
| 101 | DC01 | AD/DNS/DHCP primaire | Windows Server 2022 | pve01 | 20 |
| 102 | DC02 | AD/DNS/DHCP replica | Windows Server 2022 | pve02 | 20 |
| 110 | FILE01 | File Server + DFS | Windows Server 2022 | pve01 | 20 |
| 111 | WSUS01 | Mises à jour WSUS | Windows Server 2022 | pve01 | 20 |
| 201 | APP01 | Application métier | Debian 12 | pve02 | 80 |
| 210 | GLPI01 | Tickets/incidents IT | Debian 12 / GLPI 10.0.x | pve02 | 80 |
| 301 | PBS01 | Proxmox Backup Server | PBS 3.1 | pve01 | 50 |
| 401–410 | MON-* | Supervision | Debian 12 | pve01/02 | 60 |
| 501 | DMZ-RP | Reverse proxy | Debian 12 / Nginx | pve02 | 90 |

## 3. Windows Server

### Active Directory (DC01 → DC02)
- Forêt/domaine `example.local` (NetBIOS `EXAMPLE`), functional level 2016+.
- DC01 promus premier (`Install-ADDSForest`), DC02 en réplica → redondance d'authentification.
- **DNS** AD-integrated + zone reversal ; forwarders sortants via le WatchGuard.
- **DHCP** : scopes VLAN 30/40/70, résilient split-scope 50/50.
- **GPO** (voir `automation/provisioning/windows-dc-promote.ps1` et
  `configs/windows/gpo/README.md`) :
  - Restriction software + AppLocker niveau 1
  - LAPS (rotation mot de passe local)
  - Mappage lecteur réseau → `\\FILE01.example.local\<partage>`
  - WSUS pointé (intranet, pas de Windows Update public)
  - Firewall Windows allow-list, NTP → DC01, écran de verrouillage, audit.

### File Server (FILE01)
- Partages SMB3 : `Utilisateurs`, `Services`, `Projet`, `Logiciels`.
- NTFS + ACL par groupe AD (RBAC), quota FSRM, **DFS namespace** pour l'ubiquité.
- Dedup (optionnel) + stockage sur volume dédié, inclus dans la stratégie de backup.

### WSUS (WSUS01)
- Synchronisation planifiée (produits/classifications ciblés), anneaux :
  **Test** → **Production** via GPO.
- Réduit le trafic WAN (postes ne téléchargent pas depuis Microsoft directement).

## 4. Application métier (APP01)
- Debian 12, runtime applicatif, DB locale ou distante selon l'éditeur.
- Publiée aux **USERS/WIFI** uniquement (flux HTTP/S métier), scraping supervision,
  sauvegardée en **Tier 0/1**.

## 5. GLPI (GLPI01)
- **GLPI 10.0.x** + MariaDB + Apache, PHP durci.
- Authentification **par AD (LDAP)** : les utilisateurs du domaine ouvrent un compte
  synchronisé (pas de comptes locaux dispersés).
- Plugins typiques : `fields`, `datainventory` (inventaire des postes/VMs via agent
  FusionInventory/GLPI Agent), `reports`.
- Rôles/entités : Demandeur / Technicien / Admin IT ; SLA de réponse par criticité.
- **Publication Internet** : uniquement via le reverse proxy DMZ (`10.10.90.10`) derrière
  le WatchGuard (flux HTTPS 443), jamais de NAPT direct vers la VM.

## 6. Sauvegarde & supervision de la virtualisation
- Backup des VMs par **PBS** (incrémentaire, dédup, chiffrement) — voir
  [`backup.md`](backup.md).
- Live migration (VMID 201 illustrée dans
  [`diagrams/animated/proxmox-vm.html`](../diagrams/animated/proxmox-vm.html)) pour la
  maintenance à chaud.
- `pve-exporter` + API Proxmox → Prometheus pour l'état des nœuds/VMs/stockage.

## 7. Provenance des configs
- `configs/proxmox/pve01-network.yaml` — réseau hôte.
- `configs/proxmox/cluster.conf` — corosync/QDevice.
- `configs/proxmox/storage.cfg` — datastores.
- `automation/provisioning/proxmox-create-vms.sh` — création des VMs depuis l'inventaire.
