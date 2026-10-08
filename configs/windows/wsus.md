# WSUS — Windows Server Update Services (WSUS01)

> **Périphérique / rôle** : serveur de mise à jour `WSUS01` (`10.10.20.111`) —
> Windows Server 2022 Std, VLAN **20 SERVERS**, VM Proxmox (VMID 111).
> **Console** : `http://10.10.20.111:8530` (HTTPS client : `8531`).
> **Source de vérité** : `docs/00-architecture-reference.md` (sections 4 & 5).
>
> ⚠️ **VALEURS ANONYMISÉES** : aucun secret WSUS ; les URLs amont Microsoft sont
> les valeurs par défaut (`PUBLIC`/internet). Comptes = `<REDACTED>`.

---

## 1. Topologie — amont / aval (upstream / downstream)

- **WSUS01 = serveur autonome "amont" pour le parc** (il synchronise depuis
  Microsoft Update ; il n'y a **pas** de WSUS parent interne).
- Tous les postes (VLAN 30/40) et serveurs Windows (VLAN 20) pointent vers
  **WSUS01** via GPO (`GPO-WSUS`). Aucune machine ne va chercher les patchs
  directement sur Internet (économie de bande passante WAN Madagascar).
- Le **DMZ / reverse-proxy n'expose pas WSUS** (les patchs sortent rarement du
  VLAN interne ; flux autorisés côté FW : `10.10.20.0/24 -> WSUS01:8530/8531`,
  et WSUS01 -> `external` 443 pour la sync amont).

```
[Parc Windows]  --(GPO)-->  WSUS01:8530/8531  --(HTTPS 443)-->  Microsoft Update
   VLAN 30/40                   VLAN 20                             (via FW/WAN)
```

## 2. Synchronisation — produits & classifications

| Élément | Réglage retenu |
|---------|----------------|
| **Langues** | Français, Anglais |
| **Classifications** | Critical Updates, Security Updates, Updates, Update Rollups, Definition Updates |
| **Produits** | Windows Server 2022, Windows 10/11, Microsoft Edge, Office/MS365 C2R, .NET, SQL Server (si présent) |
| **Fréquence sync** | 2×/jour (02:00 et 14:00) |
| **Approbation auto** | classifications *Security/Critical/Definition* (sinon manuel) |

## 3. Groupes & schedule de déploiement (anneaux)

| Groupe cible | Ordre | Créneau (heure locale, Antananarivo UTC+3) |
|--------------|:-----:|--------------------------------------------|
| `Test-IT` (machines pilotes) | 1ᵉʳ | Patch Tuesday + 1 j — approuvé immédiatement |
| `Serveurs` (DC01/02, FILE01, WSUS01) | 2ᵉ | + 7 j, fenêtre maintenance 22:00–02:00 |
| `Postes` (VLAN 30/40) | 3ᵉ | + 7 j, installation 18:00–21:00 |
| `Divers` (monitors Linux, etc.) | n/a | hors WSUS (gérés `apt`/`dnf`) |

## 4. GPO de liaison (`GPO-WSUS`)

Lien : **WSUS01 / OU postes + OU serveurs**. Paramètres clés (Computer Config) :

```
Computer Configuration
 └─ Policies ─ Admin Templates ─ Windows Components ─ Windows Update
     • Configure Automatic Updates        = Enabled (4 = Auto download + schedule)
     • Specify intranet Microsoft update  = http://10.10.20.111:8530
         (statistical + target = même URL)
     • Automatic Updates detection frequency = 6 h
     • Allow non-administrators to receive update notifications = Enabled
     • Enabling UAC local / remote restricted = aligné avec GPO-Base-Postes
```

> Le groupe cible est résolu par **target group assignment** (cookie/membership
> AD) : les postes du VLAN 30/40 tombent dans `Postes`, les serveurs VLAN 20
> dans `Serveurs`. La planification d'installation est décalée (maintenance
> window) pour ne pas impacter la production métier (VLAN 80).

## 5. Rapports & nettoyage

- **Rapports** hebdo (serveur → mail supervision `mon-alert-01`) : % conformité,
  critiques non installés, groupes en retard.
- **Server Cleanup Wizard** (WSUS) planifié mensuel : expiration des superseded,
  déclinés, téléchargement non requis.
- **Base** : WSUSDB sur le datastore de la VM (250 Go, cf. plan section 5).

---

*FIN — wsus.md. Volet GPO détaillé : `gpo/README.md`. Flux pare-feu :
`configs/watchguard/firebox-policy.txt`.*
