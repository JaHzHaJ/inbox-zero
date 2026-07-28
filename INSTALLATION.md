# Gestion Mails — installation sur un poste Windows

Application locale de tri des mails et de récapitulatif quotidien (fork d'Inbox Zero).
Elle tourne sur le poste, se connecte à Outlook via Microsoft Graph et envoie le récap
par Resend.

## Deux modes de fonctionnement

Le choix est proposé **au moment de l'installation**, et se change ensuite à tout moment
avec `basculer-mode.cmd`.

| Mode | Où vivent les données | Quand le choisir |
|---|---|---|
| **partagé** *(défaut)* | Base Supabase et Redis Upstash, hébergés | Plusieurs postes se partagent une seule boîte : mêmes règles, même historique, **un seul récap par jour** |
| **local** | Base et Redis dans Docker, sur le poste | Un poste isolé, du dépannage, des essais. Autonome, ne dépend d'aucun service extérieur, mais ne se partage pas |

Le mode n'est pas un réglage à part : il est **déduit de `DATABASE_URL`**. Si l'adresse
pointe sur le poste, c'est le mode local ; sinon le mode partagé. Rien à synchroniser, et
aucun réglage ne peut affirmer le contraire de la réalité.

## Installation express

1. Ouvrir le dossier OneDrive **`Gestion Mails`** (il contient le kit et le `.env`).
   Attendre la fin de la synchronisation.
2. Double-cliquer **`installer.cmd`**.
3. Répondre aux deux questions : le **mode**, puis le **fournisseur d'IA**.

À la fin, un raccourci **Gestion Mails** apparaît sur le Bureau et la tâche planifiée
« InboxZero Recap 7h » est en place.

Premier accès : cliquer « Sign in with Microsoft » une seule fois. En mode partagé, les
règles, les jetons et l'historique étant dans la base commune, **rien n'est à recréer**.

### Options

```powershell
.\install.ps1 -Mode partage            # sans poser la question
.\install.ps1 -Mode local -Ia claude-cli
.\install.ps1 -RepoPath D:\dev\inbox-zero
.\install.ps1 -SkipTask                # sans tâche planifiée
.\install.ps1 -SecretsPath C:\chemin\.env
```

L'installeur est **idempotent** : le relancer met simplement le dépôt à jour.

## Ce que fait l'installeur

| Étape | Détail |
|---|---|
| 1 | Git, Node 24 (via fnm), pnpm — installés par `winget` si absents |
| 2 | Docker **uniquement en mode local** |
| 3 | Clone `JaHzHaJ/inbox-zero` (branche `phase2-recap`) ou le met à jour |
| 4 | Copie le `.env` et **vérifie qu'il correspond au mode demandé** |
| 5 | `pnpm install --config.enable-global-virtual-store=false` |
| 6 | `prisma generate` (**pas** `migrate` : la base partagée fait foi) |
| 7 | Fournisseur d'IA : CLI Claude, clé API, ou plus tard |
| 8 | Vérifie que la base et Redis répondent **vraiment** |
| 9 | Raccourci Bureau |
| 10 | Tâche planifiée (lun–ven 7 h, réessais toutes les 30 min jusqu'à 18 h) |
| 11 | Démarre l'application et vérifie qu'elle répond |

## Le fournisseur d'IA

Le classement des mails et les résumés passent par une IA. L'installeur propose :

| Choix | Effet |
|---|---|
| **CLI Claude** *(défaut)* | Utilise l'abonnement, aucun coût au message. ⚠️ **La session est propre à chaque machine** : sur un poste neuf, l'installeur affiche la marche à suivre et attend que vous ayez lancé `claude` puis ouvert une session |
| **Clé API** | Saisie masquée, jamais affichée ni journalisée |
| **Plus tard** | Rien n'est écrit ; le classement reste inactif jusqu'à ce que vous lanciez `.claude\configurer-ia.cmd` |

Le choix est écrit dans `apps\web\.env.local`, **propre à ce poste**. Le `.env` partagé
reste identique partout — un poste peut donc utiliser l'abonnement et l'autre une clé API.

`DEFAULT_LLMS` accepte une **liste ordonnée avec repli** : `claude-code:sonnet,anthropic:claude-sonnet-4-6`
utilise le CLI et bascule seul sur la clé API si la session Claude manque.

## Fonctionnement à deux postes

Les deux postes sont **équivalents** : chacun porte la tâche planifiée, et le premier
allumé le matin envoie le récap. Une réservation atomique du créneau
(`Schedule.nextOccurrenceAt`) garantit qu'un seul récap part, même si les deux postes
tournent en même temps. Si le poste qui a réservé le créneau disparaît avant d'envoyer
(capot rabattu, coupure), le créneau est automatiquement rendu au bout de 30 minutes et
l'autre poste prend le relais.

Avant l'envoi, chaque passage **rattrape les mails des 3 derniers jours** non encore
classés — c'est ce qui remplace les notifications Microsoft, impossibles sans adresse
publique. Le dédoublonnage s'appuie sur `ExecutedRule` : un mail déjà classé n'est jamais
reclassé, quel que soit le poste qui l'a traité.

> ⚠️ **Les deux postes doivent porter la même version du code.** Ils partagent une seule
> base : si l'un reçoit une évolution du schéma et pas l'autre, le retardataire échoue sur
> des colonnes qu'il ne connaît pas. Après une mise à jour : `git pull`, `pnpm install`,
> `prisma generate`, redémarrage — sur les deux.

## Sauvegardes

En mode partagé, **le palier gratuit de Supabase ne fait aucune sauvegarde**. La tâche
planifiée en fabrique donc une par semaine dans `%LOCALAPPDATA%\GestionMails\backups\`.

- Chaque fichier est **daté**, les **8 derniers** sont conservés (≈ 2 mois, ~25 Mo).
  Aucune n'écrase la précédente : une corruption passée inaperçue une semaine détruirait
  la seule copie saine.
- La sauvegarde est **autonome** : elle embarque les extensions PostgreSQL nécessaires,
  que `pg_dump` n'inclut pas de lui-même. Sans elles la restauration échoue.
- Elle exige PostgreSQL **ou** Docker sur le poste. Un seul poste suffit à assurer les
  sauvegardes ; le script le dit clairement s'il ne peut pas.

Sauvegarder ou restaurer à la main :

```powershell
.\.claude\sauvegarder-base.cmd
.\.claude\restaurer-base.ps1          # la plus récente, avec confirmation
```

## Quand plus rien ne marche

Double-cliquer **`remise-en-service.cmd`**. Il diagnostique, **nomme la panne** — projet
en pause, identifiants refusés, réseau bloqué, base vide, Docker éteint — et propose la
réparation correspondante.

> **Le cas le plus fréquent au retour de congés** : Supabase met les projets gratuits en
> pause après **7 jours sans activité**. Vos données sont alors **intactes** — il n'y a
> **rien à restaurer**. Un clic sur « Restore project » dans la console suffit, et le
> script attend que la base réponde. Restaurer par réflexe ferait perdre tout ce qui s'est
> passé depuis la dernière sauvegarde.

## Changer de mode

```powershell
.\basculer-mode.cmd
```

> ⚠️ Passer de **partagé à local** ne fusionne rien : les deux bases divergent à partir de
> cet instant, et il n'existe aucun moyen de les réunir ensuite.

## Vérifier que tout est en ordre

```powershell
.\.claude\verifier-installation.ps1 -Tous
```

Rejoue la même batterie dans **les deux modes** : base, Redis (y compris ses verrous),
serveur, tâche planifiée, sauvegarde présente et lisible. Vérifier le mode inactif ne
bascule rien — la configuration est reconstituée de côté, la production n'est pas touchée.

## Les secrets ne vont jamais sur GitHub

Le fork `JaHzHaJ/inbox-zero` est **public** (un fork de dépôt public ne peut pas être
privé). Rien de personnel ne doit y être poussé.

`.env` est donc transporté par **OneDrive professionnel** :
`…\OneDrive - <organisation>\Gestion Mails\.env`, ignoré par git (`.gitignore` → `.env*`).

| Service | Rôle | Variables |
|---|---|---|
| Supabase | Base Postgres partagée | `DATABASE_URL` (pooler transaction, 6543), `DIRECT_URL` (pooler session, 5432) |
| Upstash | Redis partagé (verrous entre postes) | `UPSTASH_REDIS_URL`, `UPSTASH_REDIS_TOKEN` |
| Azure AD | Connexion Outlook | `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `MICROSOFT_TENANT_ID` |
| Resend | Envoi du récap | `RESEND_API_KEY`, `RESEND_FROM_EMAIL` |

> ⚠️ `EMAIL_ENCRYPT_SECRET` et `EMAIL_ENCRYPT_SALT` doivent être **identiques sur tous les
> postes** : ce sont eux qui déchiffrent les jetons OAuth stockés en base.

**Aucune URI de redirection Azure AD à ajouter** pour un nouveau poste : tous utilisent
`http://localhost:3000/api/auth/callback/microsoft`.

### Deux détails de connexion à ne pas « corriger »

- `uselibpqcompat=true` dans les URL Supabase : sans lui, le pilote PostgreSQL de Node
  exige une autorité de certification publique et **refuse** le certificat de Supabase,
  signé par une autorité privée. La connexion reste chiffrée.
- **Pas** de `pgbouncer=true&connection_limit=1` : ce projet utilise l'adaptateur
  `@prisma/adapter-pg`, pour lequel ces paramètres sont au mieux inutiles.

## Fabriquer le kit pour un autre poste

```powershell
.\.claude\make-kit.ps1
```

Produit `Gestion-Mails-Installation.zip` dans le dossier OneDrive « Gestion Mails ». Le ZIP
se décompresse **n'importe où** : chaque script cherche ses voisins à côté de lui d'abord.
Pour un kit transmissible sans secrets : `.\.claude\make-kit.ps1 -SansSecrets`.

## Désactiver ou désinstaller

Double-cliquer **`desinstaller.cmd`** — un seul désinstalleur, qui **détecte** le mode au
lieu de le supposer.

| Choix | Effet |
|---|---|
| **1. Désactiver** *(défaut)* | Tâche désactivée, serveur arrêté. **Rien n'est supprimé** |
| **2. Désinstaller l'application** | + tâche, raccourci, conteneurs, journaux, dépôt |
| **3. Désinstaller + logiciels** | + Docker, fnm/Node, pnpm — **jamais par défaut** |

> En mode partagé, **la base Supabase et Redis Upstash ne sont jamais touchés** : l'autre
> poste continue de fonctionner. En mode local, la base est *sur ce poste* — le
> désinstalleur prévient et propose de sauvegarder d'abord.

Ne sont **jamais** touchés : les mails, les brouillons, les catégories Outlook, le `.env`
dans OneDrive.

## Vérifier que ça marche

```powershell
Start-ScheduledTask -TaskName 'InboxZero Recap 7h'
```

Puis suivre `%LOCALAPPDATA%\GestionMails\logs\digest-cron.log`. Séquence attendue :
`mode partage` → `rattrapage passe 1 : {"done":true,…}` → `envoi recap (curl 0)`.
`Get-ScheduledTaskInfo -TaskName 'InboxZero Recap 7h'` doit indiquer `LastTaskResult : 0`.

## Réveil depuis la veille (facultatif)

`WakeToRun` est activé, mais Windows l'ignore si les minuteurs de réveil sont désactivés.
Dans une invite **administrateur** :

```powershell
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setactive SCHEME_CURRENT
```

Cela ne réveille que depuis la **veille** : un poste éteint ne peut pas être réveillé.

## Pannes courantes

| Symptôme | Cause | Correction |
|---|---|---|
| Base injoignable en mode partagé | Projet Supabase en pause (7 j sans activité) | `remise-en-service.cmd` — **aucune restauration nécessaire** |
| `Tenant or user not found` | Mot de passe changé côté Supabase | Le reporter dans `DATABASE_URL` et `DIRECT_URL` |
| Les mails ne sont plus classés | Session Claude expirée sur ce poste | Lancer `claude` dans un terminal, se connecter |
| Le récap n'arrive pas | Aucun poste allumé entre 7 h et 18 h | Allumer un poste : le rattrapage couvre 3 jours |
| Récap en double | Un poste tournait encore sur l'ancienne base | **Toujours redémarrer le serveur après avoir modifié le `.env`** — `basculer-mode.cmd` le fait |
| `pnpm now wants to use the virtual store` | Config utilisateur pnpm | Déjà contourné par l'installeur |
| `Docker Desktop introuvable` | Mode local sans Docker | L'installer, ou passer en mode partagé |

Journaux : `%LOCALAPPDATA%\GestionMails\logs\` — `digest-cron.log`, `ensure-stack.log`,
`serveur.log`, `sauvegarde.log`, `catch-up-dernier.json`, `envoi-dernier.json`.
