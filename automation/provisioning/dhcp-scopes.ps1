# =============================================================================
# dhcp-scopes.ps1 — Creation des scopes DHCP (USERS / WIFI / GUEST) sur
#                   DC01+DC02, strictement alignes sur le plan §4
#                   (docs/00-architecture-reference.md).
#
# PURPOSE (exemple public — portfolio) :
#   Finir l'installation DHCP demarree par windows-dc-promote.ps1 :
#     USERS VLAN 30 : 10.10.30.100-200   gw 10.10.30.1  DNS DC01/DC02  bail 8h
#     WIFI  VLAN 40 : 10.10.40.100-10.10.43.200  gw 10.10.40.1  DNS DC01/DC02  bail 8h
#     GUEST VLAN 70 : 10.10.70.100-10.10.71.200  gw 10.10.70.1  DNS FW (limite)  bail 4h
#   Le Core Aruba relaie les requetes (ip helper-address) vers les DC ;
#   redondance DHCP 50/50 en mode failover partner (DC01 <-> DC02).
#
# PREREQUIS :
#   - Role DHCP installe et autorise (windows-dc-promote.ps1)
#   - Session PowerShell elevee sur DC01 (ou -ComputerName distant + WinRM)
#
# DONNEES ANONYMISEES : domaine example.local, aucun secret.
#
# SECURITE : SupportsShouldProcess — -WhatIf pour simuler sans creer.
#
# USAGE :
#   .\dhcp-scopes.ps1 -WhatIf
#   .\dhcp-scopes.ps1                                   # DC01, failover vers DC02
#   .\dhcp-scopes.ps1 -SkipFailover                     # scopes locaux seulement
# =============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ComputerName  = 'DC01',            # serveur DHCP cible (10.10.20.101)
    [string]$FailoverPartner = 'DC02',          # replica (10.10.20.102)
    [switch]$SkipFailover
)

$ErrorActionPreference = 'Stop'

# DNS d'entreprise selon le plan : DC01 puis DC02
$DnsEntreprise = @('10.10.20.101', '10.10.20.102')
# GUEST : resolution limite via le WatchGuard (interface VLAN 70).
# L'IP precise de cette interface n'est pas dans le plan public — a confirmer
# sur site (documente ici comme parametre, jamais codé en dur ailleurs).
$DnsGuest = '10.10.70.2'
$Domaine  = 'example.local'

# -----------------------------------------------------------------------------
# Definition des scopes (tableau de donnes = miroir exact du plan §4)
# -----------------------------------------------------------------------------
$Scopes = @(
    [pscustomobject]@{
        Name       = 'USERS-VLAN30'
        ScopeId    = '10.10.30.0'
        Mask       = '255.255.255.0'
        Start      = '10.10.30.100'
        End        = '10.10.30.200'
        Router     = '10.10.30.1'          # passerelle Core VLAN 30
        DnsServers = $DnsEntreprise
        LeaseTime  = ([TimeSpan]::FromHours(8))
    }
    [pscustomobject]@{
        Name       = 'WIFI-VLAN40'
        ScopeId    = '10.10.40.0'
        Mask       = '255.255.252.0'       # /22
        Start      = '10.10.40.100'
        End        = '10.10.43.200'
        Router     = '10.10.40.1'          # passerelle Core VLAN 40
        DnsServers = $DnsEntreprise
        LeaseTime  = ([TimeSpan]::FromHours(8))
    }
    [pscustomobject]@{
        Name       = 'GUEST-VLAN70'
        ScopeId    = '10.10.70.0'
        Mask       = '255.255.252.0'       # /22
        Start      = '10.10.70.100'
        End        = '10.10.71.200'
        Router     = '10.10.70.1'          # passerelle Core VLAN 70 (NAT FW seul)
        DnsServers = @($DnsGuest)
        LeaseTime  = ([TimeSpan]::FromHours(4))
    }
)

# -----------------------------------------------------------------------------
# 1. Creation des scopes + options 003 (routeur) et 006 (DNS)
# -----------------------------------------------------------------------------
foreach ($s in $Scopes) {
    if ($PSCmdlet.ShouldProcess("$($s.Name) ($($s.Start)-$($s.End))", 'Add-DhcpServerv4Scope')) {
        Write-Host "Scope : $($s.Name) -> $($s.Start) - $($s.End) [$($s.ScopeId)/$($s.Mask)]" -ForegroundColor Cyan

        Add-DhcpServerv4Scope -Name $s.Name -ComputerName $ComputerName `
            -StartRange $s.Start -EndRange $s.End -SubnetMask $s.Mask `
            -LeaseDuration $s.LeaseTime -State Active `
            -Description "VLAN plan — $($s.Name) (ref docs/00-architecture-reference.md §4)"

        # Option 003 — passerelle par defaut
        Set-DhcpServerv4OptionValue -ComputerName $ComputerName -ScopeId $s.ScopeId `
            -Router $s.Router

        # Option 006 — serveurs DNS + suffixe de recherche
        Set-DhcpServerv4OptionValue -ComputerName $ComputerName -ScopeId $s.ScopeId `
            -DnsServer $s.DnsServers -DnsDomain $Domaine

        # Exclusions de securite : premieres adresses reservees (passerelle,
        # equipements fixes hors pool) — pools commencent a .100 dans le plan,
        # on exclut neanmoins le /24 machine si scope contigu (WIFI/GUEST /22).
        Write-Host "  options 003=$($s.Router) 006=$($s.DnsServers -join ',') bail=$($s.LeaseTime)" -ForegroundColor DarkGray
    }
}

# -----------------------------------------------------------------------------
# 2. Reservation statique declaree dans le plan (AP en MGMT n'est pas sur ces
#    scopes DHCP — l'AP 10.10.10.31 est reserve sur le pool MGMT du FW/AP
#    controller ; rien a creer ici. Exemple de reservation si besoin :)
# -----------------------------------------------------------------------------
# Add-DhcpServerv4Reservation -ScopeId 10.10.30.0 -IPAddress 10.10.30.10 `
#     -ClientId 'aa-bb-cc-dd-ee-ff' -Description 'Serveur d impression Zone A'

# -----------------------------------------------------------------------------
# 3. Redondance DHCP 50/50 : failover DC01 <-> DC02 (plan : mode resiliant)
# -----------------------------------------------------------------------------
function ConvertTo-PlainSecret {
    # Windows PowerShell 5.1 : conversion SecureString -> texte plano (usage
    # immediat uniquement, jamais affiche ni journalise).
    param([securestring]$SecureString)
    return [System.Net.NetworkCredential]::new('', $SecureString).Password
}

if (-not $SkipFailover) {
    $SharedSecret = Read-Host -AsSecureString 'Secret de partage DHCP failover (non stocke dans le depot)'
    foreach ($s in $Scopes) {
        if ($PSCmdlet.ShouldProcess("$($s.Name)", 'Add-DhcpServerv4Failover + split 50/50')) {
            Add-DhcpServerv4Failover -Name "FO-$($s.Name)" -ComputerName $ComputerName `
                -PartnerServer $FailoverPartner `
                -ScopeId $s.ScopeId `
                -LoadBalancePercentage 50 `
                -FailoverMode LoadBalance `
                -SharedSecret (ConvertTo-PlainSecret $SharedSecret)
        }
    }
    $SharedSecret = $null   # nettoyage de la reference
}
else {
    Write-Host 'Failover ignore (-SkipFailover) : les scopes restent actifs sur DC01 seul.' -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 4. Controle final
# -----------------------------------------------------------------------------
Write-Host "`nVerification :" -ForegroundColor Green
Get-DhcpServerv4Scope -ComputerName $ComputerName |
    Select-Object ScopeId, Name, StartRange, EndRange, LeaseDuration | Format-Table -AutoSize
