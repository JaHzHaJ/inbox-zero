# Gestion Mails — installation sur un poste Windows

Application locale de tri des mails et de récapitulatif quotidien (fork d'Inbox Zero).
Elle tourne sur le poste, se connecte à Outlook via Microsoft Graph et envoie le récap
par Resend.

## Installation express

Sur le nouveau poste :

1. Ouvrir le dossier OneDrive **`Gestion Mails`** (il contient `.env`, `installer.cmd`
   et `install.ps1`). Attendre que la synchronisation soit terminée.
2. Double-cliquer **`installer.cmd`**.
3. Suivre les éventuelles demandes de confirmation (installation de Git, Node, pnpm).

À la fin, un raccourci **Gestion Mails** apparaît sur le Bureau et la tâche planifiée
« InboxZero Recap 7h » est en place.

Premier accès : cliquer « Sign in with Microsoft » une seule fois — la session est
ensuite conservée. Les règles, les jetons et l'historique du récap étant dans la base
partagée, **rien n'est à recréer** sur le second poste.

### Options

```powershell
.\install.ps1 -RepoPath D:\dev\inbox-zero   # autre emplacement
.\install.ps1 -SkipTask                     # sans tâche planifiée
.\install.ps1 -SkipSmokeTest                # sans démarrage de l'application
.\install.ps1 -SecretsPath C:\chemin\.env   # .env hors OneDrive
```

L'installeur est **idempotent** : le relancer met simplement le dépôt à jour.

## Ce que fait l'installeur

| Étape | Détail |
|---|---|
| 1 | Vérifie Git, Node 24 (via fnm) et pnpm ; les installe par `winget` si besoin |
| 2 | Clone `JaHzHaJ/inbox-zero` (branche `phase2-recap`) dans `%USERPROFILE%\dev\inbox-zero`, ou le met à jour |
| 3 | Copie `.env` depuis OneDrive et vérifie les variables essentielles |
| 4 | `pnpm install --config.enable-global-virtual-store=false` |
| 5 | `prisma generate` (**pas** `migrate` : la base partagée fait foi) |
| 6 | Crée le raccourci Bureau |
| 7 | Enregistre la tâche planifiée (lun–ven 7h, réessais toutes les 30 min jusqu'à 18h) |
| 8 | Démarre l'application et vérifie qu'elle répond |

## Fonctionnement à deux postes

Les deux postes sont **équivalents** : chacun porte la tâche planifiée, et le premier
allumé le matin envoie le récap. Une réservation atomique du créneau
(`Schedule.nextOccurrenceAt`, comparaison-et-échange) garantit qu'un seul récap part,
même si les deux postes sont allumés en même temps.

Avant l'envoi, chaque passage **rattrape les mails des 3 derniers jours** qui n'ont pas
encore été classés — c'est ce qui remplace les notifications Microsoft, impossibles sans
adresse publique. Le dédoublonnage s'appuie sur `ExecutedRule` : un mail déjà classé
n'est jamais reclassé ni re-résumé, quel que soit le poste qui l'a traité.

Si aucun poste n'est allumé à 7h, le récap part au premier démarrage suivant, avec les
mails des jours manqués (plafond : 3 jours).

## Les secrets ne vont jamais sur GitHub

Le fork `JaHzHaJ/inbox-zero` est **public** (un fork de dépôt public ne peut pas être
privé sur GitHub). Rien de personnel ne doit y être poussé.

`.env` est donc transporté par **OneDrive professionnel** :
`…\OneDrive - <organisation>\Gestion Mails\.env`. Il est ignoré par git
(`.gitignore:32` → `.env*`).

Il contient notamment le secret client Azure AD, la clé Resend, les clés de chiffrement
des jetons (`EMAIL_ENCRYPT_SECRET` / `EMAIL_ENCRYPT_SALT`) et `CRON_SECRET`.

> ⚠️ `EMAIL_ENCRYPT_SECRET` et `EMAIL_ENCRYPT_SALT` doivent être **identiques sur tous
> les postes** : ce sont eux qui déchiffrent les jetons OAuth stockés en base. Les
> modifier rend la connexion Outlook illisible.

## Comptes de service requis

Ils sont déjà configurés ; à ne refaire qu'en cas de remise à zéro.

| Service | Rôle | Variables |
|---|---|---|
| Supabase | Base Postgres partagée | `DATABASE_URL` (pooler, port 6543, `?pgbouncer=true&connection_limit=1`), `DIRECT_URL` (port 5432) |
| Upstash | Redis partagé (verrous entre postes) | `UPSTASH_REDIS_URL`, `UPSTASH_REDIS_TOKEN` |
| Azure AD | Connexion Outlook | `MICROSOFT_CLIENT_ID`, `MICROSOFT_CLIENT_SECRET`, `MICROSOFT_TENANT_ID` |
| Resend | Envoi du récap | `RESEND_API_KEY`, `RESEND_FROM_EMAIL` |

**Aucune URI de redirection Azure AD à ajouter** pour un nouveau poste : tous utilisent
le même `http://localhost:3000/api/auth/callback/microsoft`.

## Fabriquer le kit pour un autre poste

Depuis le poste déjà installé :

```powershell
.\.claude\make-kit.ps1
```

Produit `Gestion-Mails-Installation.zip` (~15 Ko) dans le dossier OneDrive
« Gestion Mails », contenant les deux scripts, la documentation, un LISEZ-MOI et
le `.env`. Le ZIP se décompresse **n'importe où** : `install.ps1` cherche le
`.env` à côté de lui en priorité.

Pour un kit à transmettre sans secrets : `.\.claude\make-kit.ps1 -SansSecrets`.

## Désactiver ou désinstaller

Double-cliquer **`desinstaller.cmd`** — un menu propose trois niveaux :

| Choix | Effet |
|---|---|
| **1. Désactiver** *(défaut)* | tâche planifiée désactivée, serveur arrêté. **Rien n'est supprimé**, on réactive par `Enable-ScheduledTask -TaskName 'InboxZero Recap 7h'` |
| **2. Désinstaller l'application** | + tâche supprimée, raccourci Bureau, conteneurs et volumes Docker, journaux, dépôt |
| **3. Désinstaller + logiciels** | + Docker Desktop, fnm/Node, pnpm — **jamais par défaut**, ils servent probablement à d'autres travaux |

Le script **énumère ce qu'il va faire et demande confirmation** avant d'agir.

Ne sont **jamais** touchés : les mails, les brouillons, les catégories Outlook,
le `.env` dans OneDrive, et la base de données hébergée le cas échéant.

## Vérifier que ça marche

```powershell
Start-ScheduledTask -TaskName 'InboxZero Recap 7h'
Get-Content "$env:USERPROFILE\dev\inbox-zero\.claude\digest-cron.log" -Wait -Tail 40
```

Séquence attendue : serveur démarré → `rattrapage passe 1 : {"done":true,…}` →
`envoi recap (curl 0)`. Puis `Get-ScheduledTaskInfo -TaskName 'InboxZero Recap 7h'`
doit indiquer `LastTaskResult : 0`.

## Réveil depuis la veille (facultatif)

`WakeToRun` est activé sur la tâche, mais Windows l'ignore si les minuteurs de réveil
sont désactivés dans le plan d'alimentation. Dans une invite **administrateur** :

```powershell
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setactive SCHEME_CURRENT
```

Cela ne réveille que depuis la **veille** : un poste éteint ne peut pas être réveillé.

## Pannes courantes

| Symptôme | Cause | Correction |
|---|---|---|
| `install.ps1 est introuvable` | `installer.cmd` seul | Copier les deux fichiers dans le même dossier |
| `Introuvable : …\Gestion Mails\.env` | OneDrive pas synchronisé | Attendre la synchronisation, ou `-SecretsPath` |
| `pnpm now wants to use the virtual store` | `enable-global-virtual-store=true` en config utilisateur | Déjà contourné par l'installeur ; en manuel, ajouter `--config.enable-global-virtual-store=false` |
| Le récap n'arrive pas | Aucun poste allumé dans la fenêtre 7h–18h | Allumer un poste : le rattrapage couvre 3 jours |
| Récap vide | Aucun mail nouveau depuis le dernier envoi | Vérifier `digest-cron.log` : `newThreadCount` |
| `Docker Desktop introuvable` | Installation par utilisateur non détectée | Le chemin est résolu dynamiquement ; sinon vérifier l'installation de Docker |

Les journaux utiles sont dans `.claude\` : `digest-cron.log`, `ensure-stack.log`,
`catch-up-last.json`, `digest-send-last.json`.
