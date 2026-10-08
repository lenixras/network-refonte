# Configuration SNMP v3 — équipements réseau example.local

> Exemple public — **aucun secret en dur**. Les passphrases SNMPv3 vivent
> exclusivement dans le fichier `.env` à la racine du dossier `automation/`
> (`SNMPV3_*`, voir `.env.example`). Les adresses ci-dessous sont exactement
> celles du plan (`docs/00-architecture-reference.md` §1/§4).

## 1. Périmètre

| Équipement | Hostname | IP (VLAN) | Engine role | Module snmp_exporter |
|------------|----------|-----------|-------------|----------------------|
| Core switch Aruba CX 6300 (VSF) | `core-sw-01.example.local` | `10.10.10.2` (VLAN 10) | L3 / lien uplink FW | `aruba_cx` |
| Access switch Zone A | `acc-sw-a1.example.local` | `10.10.10.11` (VLAN 10) | accès postes | `aruba_cx` (IF-MIB defaut) |
| Access switch Zone B | `acc-sw-b1.example.local` | `10.10.10.12` (VLAN 10) | accès postes | `aruba_cx` |
| Access switch Zone C | `acc-sw-c1.example.local` | `10.10.10.13` (VLAN 10) | accès postes | `aruba_cx` |
| WatchGuard Firebox M270 | `fw.example.local` | `10.10.10.254` (interco MGMT) | périmètre / FAI | `watchguard_firebox` |
| MikroTik hEX S (CPE Telma) | — | IP de mgmt interne **à confirmer sur site** (hors plan public ; le WAN est `PUBLIC_IP_REDACTED`) | CPE fibre | `mikrotik_hex` |
| Synology RS1221+ | `nas01.example.local` | `10.10.50.20` (VLAN 50) | stockage backup | `synology_dsm` |

## 2. Paramètres d'auth (SNMPv3, authPriv)

| Paramètre | Valeur |
|-----------|--------|
| Sécurité | `authPriv` (jamais `noAuthNoPriv`) |
| Utilisateur | `${SNMPV3_USERNAME}` (env) |
| Auth | SHA-256, passphrase `${SNMPV3_AUTH_PASSPHRASE}` (env) |
| Priv | AES-128, passphrase `${SNMPV3_PRIV_PASSPHRASE}` (env) |
| Contexte / vue | restreinte aux OID `IF-MIB`, `HOST-RESOURCES-MIB`, constructeurs |
| Port | 161/udp depuis VLAN 60 (`10.10.60.10` = snmp_exporter) uniquement — ACL sur le Core et pare-feu interne du WatchGuard |

## 3. Génération de `snmp.yml` (snmp_exporter)

Ne pas éditer `snmp.yml` à la main : le **générer** avec la commande du générateur
officiel, les passphrases restant injectées via environnement au moment du scrape :

```bash
# generator.yml (extrait — modules cités dans prometheus.yml job snmp_*)
modules:
  aruba_cx:
    walk: [sysUpTime, ifIndex, ifName, ifAlias, ifOperStatus, ifAdminStatus,
           ifSpeed, ifInErrors, ifOutErrors, ipAdEntAddr]
  watchguard_firebox:
    walk: [sysUpTime, ifName, ifOperStatus, wgHaStatus, wgPacketInterfaceStats]
  mikrotik_hex:
    walk: [sysUpTime, ifName, ifOperStatus, ifSpeed]
  synology_dsm:
    walk: [sysUpTime, ifName, ifOperStatus, diskTable, raidStatus]

auths:
  snmp_v3_example:
    version: 3
    username: ${SNMPV3_USERNAME}
    sec_level: authPriv
    auth_protocol: sha256
    priv_protocol: AES
```

```bash
docker run --rm -v "$PWD:/snmp" prom/snmp-generator generate   # -> snmp.yml
# ou, sans Docker : snmp-exporter-yamlgen (make extract && make generate)
```

## 4. Tests rapides

```bash
# Depuis mon-prom-01 (10.10.60.10), avec les variables .env exportées :
source ../../.env
snmpget -v3 -l authPriv -u "$SNMPV3_USERNAME" \
  -a SHA -A "$SNMPV3_AUTH_PASSPHRASE" -x AES -X "$SNMPV3_PRIV_PASSPHRASE" \
  10.10.10.2 sysUpTime.0

# Vérif du scrape :
curl -s "http://10.10.60.10:9116/snmp?module=aruba_cx&auth=snmp_v3_example&target=10.10.10.2" \
  | head -20
```

## 5. Règles d'or

1. **Jamais** de passphrase SNMP dans un fichier versionné, un historique shell
   ou un ticket GLPI.
2. Rotation annuelle des passphrases sur les 5 appareils gérés (Core + 3 accès +
   FW), puis `generator` → redéploiement `snmp.yml` (playbook
   `monitoring/deploy-exporters.yml`).
3. Tout accès SNMP depuis un autre sous-réseau que VLAN 10/60 doit être
   refusé par l'ACL Core **et** le pare-feu WatchGuard (défense en profondeur).
