# Windows Server 2022 — AD DS · DNS · DHCP (DC01 / DC02)

> **Périphérique / rôle** : contrôleurs de domaine `DC01` (`10.10.20.101`) et
> `DC02` (`10.10.20.102`) — **Windows Server 2022 Std**, VLAN **20 SERVERS**.
> **Forêt / domaine** : `example.local` (FQDN de service, domaine anonymisé).
> **Source de vérité** : `docs/00-architecture-reference.md` (sections 3, 4, 5).
>
> ⚠️ **VALEURS ANONYMISÉES** : SafeMode/Admin password = `CHANGEME_****` ;
> comptes de service `<REDACTED>`. Ce sont des extraits PowerShell types,
> exécutés en une seule passe de déploiement (à adapter, pas un script complet).

---

## 1. AD DS — promotion DC01 (forêt) puis DC02 (réplica)

```powershell
# --- DC01 : racine de forêt example.local (statique 10.10.20.101) ---
Install-WindowsFeature -Name AD-Domain-Services, GPMC -IncludeManagementTools

Import-Module ADDSDeployment
Install-ADDSForest `
  -DomainName "example.local" `
  -DomainNetBIOSName "EXAMPLE" `
  -ForestMode      "Win2019Forest" `
  -DomainMode      "Win2019Domain" `
  -InstallDns:$true `
  -SafeModeAdministratorPassword (ConvertTo-SecureString "CHANGEME_****" -AsPlainText -Force) `
  -NoRebootOnCompletion:$false

# --- DC02 : contrôleur additionnel de la même forêt (10.10.20.102) ---
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
Install-ADDSDomainController `
  -DomainName "example.local" `
  -SiteName "Default-First-Site-Name" `
  -SafeModeAdministratorPassword (ConvertTo-SecureString "CHANGEME_****" -AsPlainText -Force)
```

> Les deux DC sont des VM Proxmox (VMID 101 / 102, VLAN 20). Réplication AD
> **bilatérale** + PDC-Emulator FSMO sur DC01. NTP : les DC sont la source de
> temps du domaine (`manyclock`/`syncfromflags`), postes + serveurs se sync sur eux.

## 2. DNS — zones et forwarders

```powershell
Install-WindowsFeature -Name DNS -IncludeManagementTools

# Zone principale = example.local (AD-intégrée, répliquée forêt, sécurisée)
Add-DnsServerPrimaryZone -Name "example.local" -ZoneFile "example.local.dns" `
  -ReplicationScope "Forest" -DynamicUpdate "Secure"

# Forwarders vers les resolveurs FAI (anonymisés) + conditionnels internes
Set-DnsServerForwarder -IPAddress "PUBLIC_IP_REDACTED","PUBLIC_IP_REDACTED" -Recurse -UseRootHint $false

# Enregistrements fixes (hôtes plan section 4) — exemples
Add-DnsServerResourceRecordA -Name "file01" -ZoneName "example.local" -IPv4Address "10.10.20.110"
Add-DnsServerResourceRecordA -Name "wsus01" -ZoneName "example.local" -IPv4Address "10.10.20.111"
# Le reverse-proxy publié est en DMZ (10.10.90.10) — géré côté DMZ, pas ici.
```

## 3. DHCP — scopes par VLAN (relay depuis le core)

> Le **Core Aruba relaie** (`ip helper-address 10.10.20.101/102`, cf.
> `configs/aruba/core-switch.cfg`) les requêtes des VLANs clients vers les DC.
> Scopes dynamiques = VLAN **30 USERS**, **40 WIFI**, **70 GUEST** uniquement
> (SERVERS/APPS/BACKUP/MGMT = adresses statiques/réservées, pas de scope).

```powershell
Install-WindowsFeature -Name DHCP -IncludeManagementTools

# Option 015 = nom de domaine, 006 = DNS (DC01,DC02), 003 = routeur = SVI du VLAN

# --- VLAN 30 USERS : 10.10.30.100-200 /24, bail 8h ---
Add-DhcpServerv4Scope -Name "USERS-V30" -StartRange 10.10.30.100 -EndRange 10.10.30.200 `
  -SubnetMask 255.255.255.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.30.0 -OptionId 3  -Value "10.10.30.1"
Set-DhcpServerv4OptionValue -ScopeId 10.10.30.0 -OptionId 6  -Value "10.10.20.101","10.10.20.102"
Set-DhcpServerv4OptionValue -ScopeId 10.10.30.0 -OptionId 15 -Value "example.local"
Set-DhcpServerv4Scope -ScopeId 10.10.30.0 -LeaseDuration (New-TimeSpan -Hours 8)

# --- VLAN 40 WIFI : 10.10.40.100 -> 10.10.43.200 (/22), bail 8h ---
Add-DhcpServerv4Scope -Name "WIFI-V40" -StartRange 10.10.40.100 -EndRange 10.10.43.200 `
  -SubnetMask 255.255.252.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.40.0 -OptionId 3 -Value "10.10.40.1"
Set-DhcpServerv4OptionValue -ScopeId 10.10.40.0 -OptionId 6 -Value "10.10.20.101","10.10.20.102"
Set-DhcpServerv4OptionValue -ScopeId 10.10.40.0 -OptionId 15 -Value "example.local"
Set-DhcpServerv4Scope -ScopeId 10.10.40.0 -LeaseDuration (New-TimeSpan -Hours 8)

# --- VLAN 70 GUEST : 10.10.70.100 -> 10.10.71.200 (/22), bail 4h ---
Add-DhcpServerv4Scope -Name "GUEST-V70" -StartRange 10.10.70.100 -EndRange 10.10.71.200 `
  -SubnetMask 255.255.252.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.70.0 -OptionId 3 -Value "10.10.70.1"
Set-DhcpServerv4OptionValue -ScopeId 10.10.70.0 -OptionId 6 -Value "<FW-resolver>"  # résolution limitée (plan)
Set-DhcpServerv4OptionValue -ScopeId 10.10.70.0 -OptionId 15 -Value "guest.example.local"
Set-DhcpServerv4Scope -ScopeId 10.10.70.0 -LeaseDuration (New-TimeSpan -Hours 4)

# Réservation AP (section 4 : ap-corpo-01 -> 10.10.10.31) — MGMT, pas de scope :
Add-DhcpServerv4Reservation -Name "AP-corpo-01" -ScopeId <reserver-hors-scope> `
  -IPAddress 10.10.10.31 -ClientId "<AA-BB-CC-DD-EE-FF>"
```

### Failover résilient **50/50** (DC01 ↔ DC02)

```powershell
# Sur DC01 : autoriser DC02 comme partenaire, mode LoadBalance 50/50
Add-DhcpServerv4Failover -Name "V30-failover" -ScopeId 10.10.30.0 `
  -PartnerServer 10.10.20.102 -LoadBalancing -LoadBalancePercentage 50 `
  -AutoFailover -MaxClientLeadTime (New-TimeSpan -Seconds 120)
Add-DhcpServerv4Failover -Name "V40-failover" -ScopeId 10.10.40.0 `
  -PartnerServer 10.10.20.102 -LoadBalancing -LoadBalancePercentage 50 -AutoFailover
Add-DhcpServerv4Failover -Name "V70-failover" -ScopeId 10.10.70.0 `
  -PartnerServer 10.10.20.102 -LoadBalancing -LoadBalancePercentage 50 -AutoFailover
```

## 4. GPO — résumé (détail dans `gpo/README.md`)

| GPO | Effet principal |
|-----|-----------------|
| `GPO-Base-Postes` | fond d'écran d'entreprise, verrouillage écran, écrans veille |
| `GPO-Drives-FILE01` | mappage lecteurs réseau vers `\\10.10.20.110\...` (FILE01) |
| `GPO-WSUS` | cible de mises à jour → `http://10.10.20.111:8530` (voir `wsus.md`) |
| `GPO-LAPS` | mots de passe locaux gérés/rotation, sauvegarde attribute AD |
| `GPO-Firewall` | profil Windows FW activé (Domain/Private), règles entrantes restreintes |
| `GPO-NTP` | source de temps = DC01/DC02 (WMSVC/NtpServer) |
| `GPO-Admins-Locaux` | membership Restricted Groups (pas de admins locaux permanents) |
| `GPO-DNS-Suffix` | suffixe primaire `example.local`, recherche désactivée hors domaine |

---

*FIN — ad-dns-dhcp.md. Les adresses VLAN/gateways sont issues du plan section 3/4 ;
`gpo/README.md` pour le détail des GPO, `wsus.md` pour le volet patching.*
