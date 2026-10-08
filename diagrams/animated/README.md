# Diagrammes animés — SVG + CSS + JS autonomes

Chaque fichier est **auto-suffisant** : SVG inline, CSS et JavaScript vanilla, aucune bibliothèque
externe, aucune requête réseau. Toutes les adresses, VLAN et hôtes proviennent de la source de
vérité [`docs/00-architecture-reference.md`](../../docs/00-architecture-reference.md)
(données anonymisées : `PUBLIC_IP_REDACTED`, domaine `example.local`).

## Ouverture

Il suffit d'**ouvrir le fichier `.html` dans un navigateur** (double-clic ou `file://`).
Aucun serveur, aucune dépendance.

```bash
firefox diagrams/animated/failover-3-fai.html   # ou n'importe quel navigateur
```

## Contenu

| Fichier | Ce qu'il montre | Interaction |
|---------|-----------------|-------------|
| [`poste-switch-core-fw-internet.html`](./poste-switch-core-fw-internet.html) | Paquets en transit : poste (VLAN 30) → switch access CX 6100 → core CX 6300 VSF → WatchGuard M270 → Internet | lecture en boucle |
| [`failover-3-fai.html`](./failover-3-fai.html) | Politique active/active/standby des 3 FAI (Orange, Telma, Starlink), sondes 10 s, bascule et failback | boutons *Simuler une panne Orange* / *Simuler une panne Telma* / *Rétablir tout* |
| [`poste-ad-dns.html`](./poste-ad-dns.html) | Séquence de connexion : requête DNS vers `10.10.20.101`, authentification AD (Kerberos/LDAP), GPO, puis accès SMB sur FILE01 | lecture en boucle |
| [`proxmox-vm.html`](./proxmox-vm.html) | Répartition des VMID 101–501 sur pve01/pve02 (vmbr0/vmbr1, VLAN 15 MTU 9000) et **live migration de la VMID 201** (pve02 → pve01, illustration) | bouton *Rejouer la migration* |
| [`vm-backup-nas.html`](./vm-backup-nas.html) | Pipeline 3-2-1 : VM prod → PBS01 (`10.10.50.10`) → nas01 (`10.10.50.20`) → hors-site chiffré + frise de rétention GFS (7 j / 4 sem / 12 mois / 5 ans) | lecture en boucle |
| [`monitoring-alert.html`](./monitoring-alert.html) | Courbe CPU franchissant le seuil → Prometheus (`10.10.60.10`) → Alertmanager (`10.10.60.12`) → e-mail/webhook → DSI notifiée | lecture en boucle |
| [`user-glpi-ticket.html`](./user-glpi-ticket.html) | Machine à états d'un ticket GLPI sur GLPI01 (`10.10.80.110`) : Nouveau → Assigné → En cours → Résolu → Clos | lecture en boucle |

## Mouvement réduit (accessibilité)

Toutes les animations sont **désactivées par défaut** et ne s'exécutent que sous
`@media (prefers-reduced-motion: no-preference)`. Si le système déclare
`prefers-reduced-motion: reduce` :

- aucun paquet, aucune trajectoire, aucun clignotement n'est animé ;
- le **état statique final** (ou l'état de référence documentaire) reste entièrement visible —
  y compris sans JavaScript, car la structure SVG et les styles de base sont rendus tels quels ;
- un bandeau **« Mouvement réduit détecté »** s'affiche en bas de chaque figure.

Les interactions explicites (boutons de failover, rejeu de migration) restent utilisables :
elles changent états et couleurs, sans mouvement.

> Note : le scénario de bascule respecte `docs/networking.md` §7 — Starlink n'est activé
> que si **Orange ET Telma** sont indisponibles ; une panne d'Orange seul reporte le trafic
> sur Telma.
