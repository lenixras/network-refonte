# Synology DS — Snapshot Replication (cible de sauvegarde)

> **Périphérique** : Synology RS1221+ — **DSM 7.2** — `nas01.example.local`
> **Rôle** : cible de sauvegarde / archive (3ᵉ copie de la stratégie 3-2-1)
> **VLAN / IP** : `10.10.50.20` — VLAN **50 BACKUP** (MTU 9000, passerelle `10.10.50.1`)
> **Source de vérité** : `docs/00-architecture-reference.md` (sections 1, 4, 5, 7)
>
> ⚠️ **VALEURS ANONYMISÉES** : endpoint hors-site `OFFSITE_ENDPOINT_REDACTED`,
> identifiants / clés de chiffrement / passphrase = `<REDACTED>` / `CHANGEME_****`.
> DSM étant un GUI, ce fichier est en Markdown (tâches décrites, pas du CLI).

---

## 1. Partages (Shared Folders)

| Dossier | Usage | Qui écrit | Chiffré | Compression |
|---------|-------|-----------|:------:|:-----------:|
| `backup-pbs` | datastore cible PBS (réplication distante des backups VM) | PBS01 (`10.10.50.10`) | oui | oui (Zstd) |
| `backup-win` | images/exports Windows (VHDX, exports SQL, sysstate) | WSUS01/FILE01/DC (agents) | oui | non |
| `archive` | rétention long terme (comptabilité, projets clos) | admins MGMT | oui | oui |

- Volume unique **Btrfs** sur pool RAID (redondance locale).
- Options volume : *data scrubbing* planifié, *snapshot* Btrfs (cf. §3).

## 2. Btrfs + chiffrement

- **Système de fichiers Btrfs** → snapshots instantanés (CoW) + intégrité (scrub).
- **Dossier chiffré** (AES-256) pour chaque partage de backup. La clé de
  déchiffrement est stockée **uniquement** sur le serveur, jamais dans une règle
  Snapshot Replication ; en cas de restauration hors-site, la passphrase est
  nécessaire → consignée en coffre (hors dépôt) : `CHANGEME_****`.
- Déduplication/compression activée sur `backup-pbs` et `archive`.

## 3. Snapshot Replication — planification

- **Snapshots locaux (Btrfs)** sur `backup-pbs`, `backup-win`, `archive` :
  - toutes les **2 h** en heures ouvrées + **1 quotidienne** 18:30 ;
  - **rotation** : 32 snapshots horaires / 7 quotidiens (retention GFS-lite).
- **Réplication NAS → NAS/hors-site (off-site)** :
  - Destination : `OFFSITE_ENDPOINT_REDACTED` (storage objet / 2ᵉ Synology distant),
    tunnel **HTTPS** + chiffrement au repos, **transfer encryption** ON.
  - Fréquence : **quotidienne 19:00** (fenêtre sauvegarde, hors PBR métier) +
    **incremental** toutes les 6 h si écart > seuil.
  - Sens : *one-way backup* (la destination n'est pas en écriture interactive).
  - Bandeau : priorisé sur VLAN 50, bridé pour ne pas saturer le WAN Telma
    (rappel : route backup/ PBS → WAN Telma, cf. `watchguard/wan-failover.txt`).

## 4. Rétention (par classe — cf. `backup.md`)

| Classe | Local (NAS) | Hors-site | Garde légale |
|--------|-------------|-----------|--------------|
| **Tier 0** (DC, PBS, NAS config) | 30 j | 90 j | archive `archive` 5 ans |
| **Tier 1** (APP01, GLPI01, FILE01) | 14 j | 30 j | — |
| **Tier 2** (WSUS, monitors, divers) | 7 j | 14 j | — |

> RPO/RTO cible par classe sont définis dans `docs/backup.md` ; ce fichier ne
> décrit que le volet **Synology / Snapshot Replication**.

## 5. Intégrité & alerting

- **Tâche de vérification (Data Guard / scrub)** : hebdomadaire dim. 03:00.
- **Notification** SMTP vers le groupe supervision (`mon-alert-01` / mail) sur :
  échec réplication, volume > 85 %, snapshot manquant, disque dégradé.
- **Test de restauration** : trimestriel, une VM Tier 0 depuis `backup-pbs` →
  restauration sur PBS01 puis re-provision Proxmox (cf. runbook `backup.md`).

---

*FIN — snapshot-replication.md (illustratif). Coordonné avec `proxmox/storage.cfg`
(entry PBS `dist-pbs`) et `docs/backup.md`.*
