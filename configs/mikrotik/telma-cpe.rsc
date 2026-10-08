# ============================================================================
# FICHIER : telma-cpe.rsc  (EXTRAIT DE CONFIGURATION — données anonymisées — configuration MikroTik)
# PERIPHERIQUE : MikroTik hEX S (RB750Gr3) — RouterOS v7.x
# ROLE : CPE Fibre TELMA (secondaire) — simple handoff vers le WatchGuard.
#        Ne doit RIEN exposer : pas de service public, pas d'admin distant.
# SOURCE DE VERITE : docs/00-architecture-reference.md (section 2, ligne 10)
# ----------------------------------------------------------------------------
# VALEURS ANONYMISEES :
#   WAN/ISP  -> PUBLIC_IP_REDACTED / PUBLIC_GW_REDACTED (contrat Telma)
#   interco CPE<->FW (handoff prive hors plan 10.10.10.0) -> 198.51.100.0/30
#            (documentation TEST-NET-2 RFC5737 ; jamais une IP interne reelle)
#   secrets  -> <REDACTED> / CHANGEME_****
#   Domaine interne : example.local (le FW est fw.example.local)
# ============================================================================
#/interface list
:add name=WAN comment="vers FAI Telma"
:add name=LAN comment="vers WatchGuard optional1 (handoff)"
#
#/interface ethernet
:set [find default-name=ether1] name=WAN-Telma
:set [find default-name=ether2] name=LAN-FW
#
#/interface pppoe-client
# Telma : termination PPPoE sur le CPE (alternative possible : dhcp-client)
:add name=telma-pppoe interface=WAN-Telma user="telma-<REDACTED>" \
    password="<REDACTED>" add-default-route=yes default-route-distance=10 \
    use-peer-dns=no comment="WAN principal FAI Telma"
#
#/ip address
# adresse WAN publique fournie par Telma (PPP -> PUBLIC_IP_REDACTED)
# interco prive vers le Firebox sur /30 (handoff, pas de NAT ici)
:add address=198.51.100.1/30 interface=LAN-FW comment="CPE -> FW optional1"
#
#/ip route
# le CCE achemine vers Internet via pppoe ; le FW est la seule destination LAN.
# (statique explicite vers le WatchGuard = next-hop du LAN)
:add dst-address=0.0.0.0/0 gateway=telma-pppoe comment="defaut via Telma"
:add dst-address=198.51.100.2/32 gateway=LAN-FW comment="host FW (fw.example.local)"
#
#/ip pool
:add name=lan-pool ranges=198.51.100.2-198.51.100.2
#
#/ip dhcp-server
:add name=lan-dhcp interface=LAN-FW address-pool=lan-pool disabled=no \
    comment="reservation unique -> WatchGuard (optionnel, statique prefere)"
#
# ----------------------------------------------------------------------------
# FIREWALL MINIMAL : AUCUNE EXPOSITION. On ne fait que handoff.
# ----------------------------------------------------------------------------
#/ip firewall filter
:add chain=input in-interface-list=WAN action=drop comment="DROP tout inbound WAN"
:add chain=input connection-state=established,related action=accept
:add chain=input in-interface-list=LAN src-address=198.51.100.2/32 \
    action=accept comment="admin Winbox/API UNIQUEMENT depuis le FW"
:add chain=input action=drop comment="default deny input"
:add chain=forward connection-state=established,related action=accept
:add chain=forward in-interface-list=LAN out-interface-list=WAN action=accept \
    comment="LAN(=FW) vers Internet autorise"
:add chain=forward in-interface-list=WAN action=drop comment="pas de transit entrant"
#
# ----------------------------------------------------------------------------
# DURCISSEMENT : couper les services accessibles depuis WAN.
# ----------------------------------------------------------------------------
#/ip service
;set telnet disabled=yes
;set ftp disabled=yes
;set api disabled=yes
;set api-ssl disabled=yes
;set winbox address=198.51.100.0/30 port=8291 comment="Winbox LAN only"
#
# ----------------------------------------------------------------------------
# divers : NTP interne (DC), timezone, pas de upnp
# ----------------------------------------------------------------------------
#/system clock
:set time-zone-name=Indian/Antananarivo
#/system ntp client
:set enabled=yes primary-ntp=10.10.20.101 secondary-ntp=10.10.20.102
#
# NOTE : ce CPE ne porte AUCUNE regle de server-publish ni de routage interne.
# Tout le perimetre (NAT/PBR/failover) est assure par le WatchGuard (see
# configs/watchguard/). Public IP = PUBLIC_IP_REDACTED (anonymisee).
# ============================================================================
# FIN — telma-cpe.rsc (extrait)
# ============================================================================
