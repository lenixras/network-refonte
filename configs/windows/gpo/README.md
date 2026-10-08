# GPO — registre des stratégies de groupe (forêt `example.local`)

> **Source de vérité** : `docs/00-architecture-reference.md` (sections 3, 4, 5).
> **Appliquées par** : DC01 (`10.10.20.101`) / DC02 (`10.10.20.102`) —
> Windows Server 2022, GPMC. **Liaison** = OU du domaine. Les cibles sont des
> **groupes de sécurité** (filtre WMI/Security Filtering), pas des OUs machines.
>
> ⚠️ **VALEURS ANONYMISÉES** : aucun secret ; les références de fichiers
> (fonds, scripts) pointent des partages internes (`\\FILE01`, `10.10.20.110`).
> Ceci est le **résumé** ; les snippets complets sont dans `../ad-dns-dhcp.md`
> et `../wsus.md`.

---

## 1. Table des GPO

| # | GPO (lien GPMC) | Liaison (OU) | Cible (groupe) | Paramètres clés |
|---|-----------------|--------------|----------------|-----------------|
| 1 | `GPO-Base-Postes` | OU `Postes` | `GRP-Postes` (VLAN 30/40) | fond d'écran entreprise, veille/verrou 10 min, désactiver USB storage (audit), politique mots de passe écran |
| 2 | `GPO-Drives-FILE01` | OU `Postes` | `GRP-Postes` | mappage préférentiel lecteurs → `\\10.10.20.110\Commun`, `\Projet`, `\Users` (item-level targeting par groupe AD) |
| 3 | `GPO-WSUS` | OU `Postes` + OU `Serveurs` | `GRP-WSUS-*` | intranet update = `http://10.10.20.111:8530`, install planifiée, rings (cf. `wsus.md`) |
| 4 | `GPO-LAPS` | OU `Postes` + `Serveurs` | `Domain Computers` | rotation mot de passe admin local (30 j, complexité 14 car.), stockage attribut AD, lecture limitée au groupe `LAPS-Readers` |
| 5 | `GPO-Firewall` | racine domaine | `Domain Computers` | Windows Firewall ON (Domain/Private/Public), inbound restrictif, exceptions par serveur (WSUS/SMB) |
| 6 | `GPO-NTP` | racine domaine | `Domain Computers` + `Domain Controllers` | source temps = DC01/DC02 (`\\example.local,0x9`), type NTP client |
| 7 | `GPO-Admins-Locaux` | OU `Postes` + `Serveurs` | `GRP-IT-Admins` | Restricted Groups : pas d'admins locaux permanents, élévation JIT via groupe temporaire |
| 8 | `GPO-DNS-Suffix` | OU `Postes` | `GRP-Postes` | suffixe primaire `example.local`, désactiver enregistrement DNS hors domaine, recherche par connexion |

## 2. Ordre d'application / héritage

- `GPO-Firewall` et `GPO-NTP` sont liés à la **racine du domaine** (plus large,
  appliqués aux DC comme aux membres) → **Enforced (No Override)**.
- Les GPO postes (1,2,8) sont limitées à l'OU `Postes` : elles **n'impactent pas**
  les serveurs (OU `Serveurs`) pour éviter les restrictions USB/écran sur DC.
- **Loopback (Merge)** est activé uniquement sur l'OU `Postes` (mode *Replace*)
  pour les stratégies utilisateur liées aux machines communes (kiosques WiFi 40).

## 3. Conventions & gouvernance

- **Nommage** : `GPO-<Rôle>-<Portée>` (ex. `GPO-Drives-FILE01`).
- **Documentation** : description GPMC renseignée + lien vers la change request
  GLPI (`GLPI01` `10.10.80.110`).
- **Test** : chaque nouvelle GPO passe d'abord par l'anneau `Test-IT`
  (cf. `wsus.md` §3) avant déploiement `Postes`/`Serveurs`.
- **Backout** : toute liaison est désactivable (Link Enabled = Off) sans
  suppression ; sauvegarde `Backup-GPO` planifiée sur `\\FILE01\GPO-Backups`
  (copiée ensuite dans `backup-win` NAS, cf. `../synology/snapshot-replication.md`).

---

*FIN — gpo/README.md. Détails PowerShell d'installation AD/DNS/DHCP : `../ad-dns-dhcp.md`.*
