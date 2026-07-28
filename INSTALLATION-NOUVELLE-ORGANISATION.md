# Gestion Mails — installer chez une NOUVELLE organisation

Ce guide s'adresse à une organisation Microsoft 365 qui découvre l'application :
aucun compte de service n'existe encore, aucun secret n'est fourni. Le kit
générique (`Gestion-Mails-Kit-Generique.zip`) contient un **assistant** qui
construit la configuration pas à pas — ce document donne le détail de chaque
étape et sert de référence.

Pour ajouter un poste à une installation **déjà en service**, utiliser l'autre
kit et l'autre guide : [INSTALLATION.md](INSTALLATION.md).

## Licence — à lire avant de commencer

Le logiciel est un fork d'[Inbox Zero](https://github.com/elie222/inbox-zero),
sous licence AGPL v3 avec clauses additionnelles de l'éditeur amont :

- **exemption** pour un usage personnel, éducatif, de recherche, et pour les
  organisations de **moins de 5 utilisateurs** du logiciel ;
- à partir de 5 utilisateurs en entreprise : licence à obtenir auprès
  d'Inbox Zero Inc. ;
- **interdiction de monétiser** le logiciel lui-même (vente d'accès, offre
  payante, intégration dans un produit commercial).

## Prérequis

| Quoi | Détail |
|---|---|
| Poste | Windows 10/11 ; l'application tourne **sur le poste** (`http://localhost:3000`) |
| Boîte mail | Licence Microsoft 365 avec **Exchange Online** (la boîte à suivre) |
| Droits Azure | Pouvoir créer une inscription d'application **et accorder le consentement administrateur** dans le tenant |
| Mode local | Docker Desktop (installé automatiquement si absent) |
| IA | Un abonnement Claude (CLI, recommandé — aucun coût au message) **ou** une clé API Anthropic |

## Choisir le mode

| | **local** *(défaut)* | **partagé** |
|---|---|---|
| Données | PostgreSQL + Redis dans Docker, sur le poste | Supabase + Upstash (hébergés, paliers gratuits) |
| Comptes à créer | Azure AD + Resend seulement | + Supabase + Upstash |
| Multi-postes | non | oui (un seul récap par jour, historique commun) |

Commencer en **local** est le plus simple ; `basculer-mode.cmd` permet de
passer en partagé plus tard (l'assistant sait générer les deux configurations).

## 1. Application Azure AD (une seule fois, par un administrateur)

1. <https://portal.azure.com> → **Microsoft Entra ID** → **App registrations**
   → **New registration**.
2. Nom libre (ex. « Gestion Mails ») ; comptes : **de cet annuaire uniquement**
   (single tenant, recommandé).
3. **Redirect URI** — plateforme **Web** — ajouter les **trois** adresses :
   - `http://localhost:3000/api/auth/callback/microsoft`
   - `http://localhost:3000/api/outlook/linking/callback`
   - `http://localhost:3000/api/outlook/admin-consent/callback`

   > ⚠️ La troisième manque dans la documentation amont (`docs/hosting/microsoft-oauth.mdx`) ;
   > sans elle, le parcours de consentement administrateur échoue.
4. **API permissions** → *Add a permission* → **Microsoft Graph** →
   **Delegated** : `openid`, `profile`, `email`, `offline_access`, `User.Read`,
   `Mail.ReadWrite`, `Mail.Send`, `MailboxSettings.ReadWrite` — puis bouton
   **Grant admin consent**.
5. **Certificates & secrets** → *New client secret* → copier la colonne
   **Value** (⚠️ pas *Secret ID*) : elle n'est visible qu'une seule fois.
6. Page **Overview** : relever **Application (client) ID** et
   **Directory (tenant) ID**.

L'assistant demandera ces trois valeurs et vérifie le tenant en ligne.

## 2. Resend (envoi du récap)

1. Créer le compte sur <https://resend.com> **avec l'adresse de la boîte
   suivie** : sans domaine vérifié, le palier gratuit ne livre **qu'au
   propriétaire du compte Resend**.
2. *API Keys* → *Create API Key* → copier la clé (`re_…`).
3. L'expéditeur par défaut `Gestion Mails <onboarding@resend.dev>` convient.
   Pour envoyer les récaps à **plusieurs personnes**, vérifier un domaine dans
   Resend (2-3 enregistrements DNS) et prendre un expéditeur de ce domaine.

## 3. Supabase et Upstash (mode partagé uniquement)

- **Supabase** (<https://supabase.com>) : *New project*, puis bouton
  **Connect** ; relever les **deux** chaînes :
  - *Transaction pooler* (port **6543**) → `DATABASE_URL`
  - *Session pooler* (port **5432**) → `DIRECT_URL`

  L'assistant ajoute lui-même `?uselibpqcompat=true&sslmode=require` (sans
  quoi le pilote Node refuse le certificat Supabase) et retire un éventuel
  `pgbouncer=true`. ⚠️ Le palier gratuit met le projet **en pause après 7 jours
  sans activité** (données intactes — « Restore project » suffit) et ne fait
  **aucune sauvegarde** : l'application en fait une par semaine sur le poste.
- **Upstash** (<https://upstash.com>) : *Create database* (Redis), encadré
  **REST API** : relever `UPSTASH_REDIS_REST_URL` (https) et le
  `UPSTASH_REDIS_REST_TOKEN`.

## 4. Installation

1. Décompresser `Gestion-Mails-Kit-Generique.zip` n'importe où (le Bureau
   convient).
2. Double-cliquer **`installer.cmd`**.
3. Répondre à la question du **mode** (Entrée = local).
4. Faute de `.env`, l'installeur propose de lancer **l'assistant de
   configuration** : répondre aux questions des sections 1 à 3 ci-dessus.
   (L'assistant peut aussi être lancé seul, avant : `configurer-services.cmd`.)
5. L'installeur enchaîne : outils, clonage, dépendances, **création du schéma
   de base** (première installation), fournisseur d'**IA** (CLI Claude par
   défaut), raccourci Bureau, tâche planifiée « récap 7 h », test de fumée.

L'assistant **génère lui-même** les secrets internes (chiffrement des jetons,
clés d'API internes…) : rien à fournir, et le fichier `.env` produit est
propre à votre organisation. **Il contient des secrets : ne pas le diffuser.**

## 5. Premier accès

1. Raccourci **Gestion Mails** sur le Bureau → « Sign in with Microsoft » avec
   le compte de la boîte suivie.
2. Si l'administrateur n'a pas encore accordé le consentement : ouvrir
   `http://localhost:3000/login/microsoft-admin-consent` (parcours guidé).
3. Dérouler l'accueil : règles de tri (en français), récap quotidien,
   brouillons automatiques (activables ou non).

## 6. Vérifier, mettre à jour, dépanner

```powershell
.\.claude\verifier-installation.ps1        # batterie de contrôles
```

- **Mise à jour** : relancer `installer.cmd` (idempotent : il met à jour le
  dépôt et les dépendances).
- **Panne** : double-cliquer `remise-en-service.cmd` — il nomme la panne et
  propose la réparation.
- **Sauvegardes** : hebdomadaires, automatiques, dans
  `%LOCALAPPDATA%\GestionMails\backups\`.

## Limites connues

- L'application est servie sur **`http://localhost:3000`** du poste — pas de
  déploiement serveur/HTTPS avec ce kit.
- **Une boîte mail suivie** par installation (mono-boîte par défaut).
- Avec le CLI Claude, la **session est propre à chaque poste** : lancer
  `claude` et se connecter une fois sur chaque machine.
- Les récaps ne partent que si un poste est **allumé** entre 7 h et 18 h
  (rattrapage automatique sur 3 jours).
