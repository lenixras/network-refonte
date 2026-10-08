# =============================================================================
# windows-dc-promote.ps1 — Installation des roles AD DS / DNS / DHCP et
#                          promotion en controleur de domaine (foret
#                          example.local) selon le plan d'architecture.
#
# PURPOSE (exemple publié — données anonymisées) :
#   Automatiser la promotion DC01 (creation foret) et DC02 (replica) sur
#   Windows Server 2022, avec adressage statique strict du plan
#   (docs/00-architecture-reference.md §4) : DC01 = 10.10.20.101,
#   DC02 = 10.10.20.102, passerelle 10.10.20.1 (Core), DNS = les deux DC.
#
# PREREQUIS :
#   - Session PowerShell elevee (Administrator) sur la VM fraiche (join domain
#     non requis pour DC01 ; DC02 doit joindre la foret existante)
#   - VM demarrees via provisioning/proxmox-create-vms.sh (bridage VLAN 20)
#   - Module NetAdapter / ServerManager / ADDSDeployment (Windows Server)
#
# DONNEES ANONYMISEES :
#   - Domaine : example.local (NetBIOS EXAMPLE)
#   - Aucun mot de passe en dur : DSRM et compte de jointure saisis via
#     Read-Host -AsSecureString (ou transmis en parametre SecureString).
#
# SECURITE : SupportsShouldProcess — utiliser -WhatIf pour simuler.
#
# USAGE :
#   # Simulation :
#   .\windows-dc-promote.ps1 -Role Primary -WhatIf
#   # DC01 (cree la foret) :
#   .\windows-dc-promote.ps1 -Role Primary -Ipv4 10.10.20.101
#   # DC02 (rejoint la foret) :
#   .\windows-dc-promote.ps1 -Role Replica -Ipv4 10.10.20.102 -JoinCredential (Get-Credential)
# =============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Primary = cree la foret (DC01) ; Replica = jointure (DC02)
    [ValidateSet('Primary', 'Replica')]
    [string]$Role = 'Primary',

    # Identite machine selon le plan
    [ValidatePattern('^(DC01|DC02)$')]
    [string]$ComputerName = 'DC01',

    # IP planifiee : DC01=10.10.20.101 / DC02=10.10.20.102 (VLAN 20 SERVERS)
    [string]$Ipv4 = '10.10.20.101',
    [string]$Prefix = '/24',                    # 10.10.20.0/24
    [string]$Gateway = '10.10.20.1',            # passerelle Core (VLAN 20)
    [string]$InterfaceAlias = 'Ethernet',

    # Foret / domaine (anonymises)
    [string]$DomainName = 'example.local',
    [string]$DomainNetbiosName = 'EXAMPLE',

    # Forwarders DNS : resolvers amont des FAI — non publies dans ce depot
    # (PUBLIC_IP_REDACTED). Par defaut : racines (hint), a remplacer sur site.
    [string[]]$DnsForwarders = @(),

    # Compte local / mot de passe DSRM : jamais en clair
    [pscredential]$JoinCredential,              # requis pour Replica
    [securestring]$DsrmPassword                 # si absent -> saisie interactive

)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# 0. Validation pre-vol
# -----------------------------------------------------------------------------
$expectedIp = @{ DC01 = '10.10.20.101'; DC02 = '10.10.20.102' }[$ComputerName]
if ($Ipv4 -ne $expectedIp) {
    Write-Error "IP $Ipv4 contredit le plan d'adressage ($ComputerName doit etre $expectedIp). Abandon."
}
if ($Role -eq 'Primary' -and $DsrmPassword -eq $null) {
    # Saisie securisee : le mot de passe ne transite jamais en clair
    $DsrmPassword = Read-Host -AsSecureString 'Mot de passe DSRM (AskRecovery) pour la foret example.local'
}
if ($Role -eq 'Replica' -and $JoinCredential -eq $null) {
    $JoinCredential = Get-Credential -Message 'Compte administrateur AD pour joindre example.local (ex: EXAMPLE\Administrateur)'
    if (-not $DsrmPassword) {
        $DsrmPassword = Read-Host -AsSecureString 'Mot de passe DSRM (identique sur les DC)'
    }
}

# -----------------------------------------------------------------------------
# 1. IP statique conforme au plan (VLAN 20 SERVERS, gw Core 10.10.20.1)
# -----------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess("Interface $InterfaceAlias", "Configurer IP statique $Ipv4$Prefix")) {
    Write-Host "[1/5] Adressage IP statique..." -ForegroundColor Cyan
    Get-NetAdapter -InterfaceAlias $InterfaceAlias `
        | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetAdapter -InterfaceAlias $InterfaceAlias `
        | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $Ipv4 `
        -PrefixLength ([int]($Prefix.TrimStart('/'))) -DefaultGateway $Gateway | Out-Null

    # DNS : la premiere reference est l'autre DC (resilience), l'autre est local
    $dnsPairs = @{ DC01 = @('10.10.20.102', '127.0.0.1'); DC02 = @('10.10.20.101', '127.0.0.1') }[$ComputerName]
    Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $dnsPairs
    Set-DnsClient -InterfaceAlias $InterfaceAlias -ConnectionSpecificSuffix 'example.local'
}

# -----------------------------------------------------------------------------
# 2. Features : AD DS + DNS + DHCP (le role DHCP est configure dans
#    provisioning/dhcp-scopes.ps1 — scopes USERS/WIFI/GUEST du plan)
# -----------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($ComputerName, 'Install-WindowsFeature AD-Domain-Services, DNS, DHCP')) {
    Write-Host "[2/5] Installation des roles AD DS / DNS / DHCP..." -ForegroundColor Cyan
    Install-WindowsFeature -Name AD-Domain-Services, DNS, DHCP `
        -IncludeManagementTools -Restart:$false |
        Select-Object @{n='Feature';e={$_.Success}}, RestartRequired | Format-Table
}

# -----------------------------------------------------------------------------
# 3. Promotion
# -----------------------------------------------------------------------------
if ($Role -eq 'Primary') {
    # --- DC01 : creation de la foret example.local ---
    if ($PSCmdlet.ShouldProcess($DomainName, 'Install-ADDSForest')) {
        Write-Host "[3/5] Creation de la foret $DomainName (NetBIOS $DomainNetbiosName)..." -ForegroundColor Cyan
        Install-ADDSForest `
            -DomainName $DomainName `
            -DomainNetbiosName $DomainNetbiosName `
            -SafeModeAdministratorPassword $DsrmPassword `
            -ForestMode 'WinThreshold' `          # WS2022
            -DomainMode 'WinThreshold' `
            -InstallDns:$true `
            -NoRebootOnCompletion:$false `
            -Force
        Write-Host "Foret creee. Reboot automatique puis completer les forwarders a l'etape 4." -ForegroundColor Green
    }
}
else {
    # --- DC02 : replica dans la foret existante ---
    if ($PSCmdlet.ShouldProcess($DomainName, 'Add-Computer + Install-ADDSDomainController')) {
        Write-Host "[3/5] Jointure du domaine puis promotion en replica..." -ForegroundColor Cyan
        Add-Computer -DomainName $DomainName -Credential $JoinCredential -Restart:$false -Force

        Install-ADDSDomainController `
            -DomainName $DomainName `
            -SafeModeAdministratorPassword $DsrmPassword `
            -Credential $JoinCredential `
            -InstallDns:$true `
            -SiteName 'Default-First-Site-Name' `
            -NoRebootOnCompletion:$false `
            -Force
    }
}

# -----------------------------------------------------------------------------
# 4. Forwarders DNS (recursif sortant vers FAI — anonymise PUBLIC_IP_REDACTED)
# -----------------------------------------------------------------------------
if ($DnsForwarders.Count -gt 0 -and $PSCmdlet.ShouldProcess('DNS Server', 'Set-DnsServerForwarder')) {
    Write-Host "[4/5] Configuration des forwarders : $($DnsForwarders -join ', ')" -ForegroundColor Cyan
    Set-DnsServerForwarder -IPAddress $DnsForwarders
}
else {
    Write-Host "[4/5] Aucun forwarder fourni : recursion via racines (hint). A remplacer par les resolvers FAI (PUBLIC_IP_REDACTED)." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 5. Autorisation DHCP (les scopes sont crees par dhcp-scopes.ps1)
# -----------------------------------------------------------------------------
if ($PSCmdlet.ShouldProcess('DHCP Server', 'Add-DhcpServerInDC')) {
    Write-Host "[5/5] Autorisation du serveur DHCP dans l'AD..." -ForegroundColor Cyan
    Add-DhcpServerInDC -DnsName "$($ComputerName.ToLower()).$DomainName"
}

Write-Host "`nTermine. Verifications post-install :" -ForegroundColor Green
Write-Host "  dcdiag /v /c /e"
Write-Host "  repadmin /showrepl"
Write-Host "  Get-DhcpServerSetting | fl ServiceRunningState,IsAuthorized"
