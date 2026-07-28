<#
.SYNOPSIS
  Construit le fichier .env complet d'une NOUVELLE organisation.

.DESCRIPTION
  Assistant de premiere installation : guide la creation des comptes de
  service (application Azure AD, Resend, et en mode partage Supabase +
  Upstash), valide chaque valeur saisie, genere les secrets internes, puis
  ecrit un .env complet a partir du gabarit modele.env.

  Aucun secret n'est affiche a l'ecran ni ecrit dans un journal. Le fichier
  PRODUIT contient des secrets : ne jamais le committer ni le diffuser.

  Chaque valeur peut etre passee en parametre : quand rien ne manque, le
  script ne pose aucune question (tests, automatisation). En contexte non
  interactif, une valeur manquante arrete tout avec un message clair.

.EXAMPLE
  .\configurer-services.ps1
  .\configurer-services.ps1 -Mode partage
  .\configurer-services.ps1 -Mode local -MicrosoftClientId <guid> -MicrosoftTenantId <guid> -MicrosoftClientSecret <valeur> -ResendApiKey re_xxx -Sortie C:\kit
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'partage')]
  [string] $Mode,
  [string] $MicrosoftClientId,
  [string] $MicrosoftClientSecret,
  [string] $MicrosoftTenantId,
  [string] $ResendApiKey,
  [string] $ResendFromEmail,
  [string] $DatabaseUrl,
  [string] $DirectUrl,
  [string] $UpstashRedisUrl,
  [string] $UpstashRedisToken,
  [string] $Sortie,
  [string] $ModeleEnv,
  [switch] $SansValidationTenant,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Sous Windows PowerShell 5.1, $PSScriptRoot est vide pendant l'evaluation des
# valeurs par defaut des parametres : on ne peut le lire qu'ici, dans le corps.
if (-not $Sortie) { $Sortie = $PSScriptRoot }

function Titre($t) { Write-Host "`n>>> $t" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Avert($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }
function Stop2($t) { Write-Host "    [ECHEC] $t" -ForegroundColor Red; exit 1 }

# Ce script vit dans .claude\ du depot ET a plat dans le kit decompresse :
# ses voisins se cherchent dans les deux dispositions.
function Voisin($nom) {
  $aCote = Join-Path $PSScriptRoot $nom
  if (Test-Path $aCote) { return $aCote }
  $dansDepot = Join-Path (Split-Path $PSScriptRoot -Parent) ".claude\$nom"
  if (Test-Path $dansDepot) { return $dansDepot }
  return $null
}

# Un Read-Host en contexte non interactif lirait une fin de fichier et
# tournerait en boucle : on ne pose des questions que si une console repond.
$script:Interactif = -not [Console]::IsInputRedirected

function NouveauSecretHex([int] $octets) {
  $tampon = New-Object byte[] $octets
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try { $rng.GetBytes($tampon) } finally { $rng.Dispose() }
  return (($tampon | ForEach-Object { $_.ToString('x2') }) -join '')
}

function LireSecretMasque($invite) {
  $secure = Read-Host $invite -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function EstGuid($s) {
  $g = [guid]::Empty
  return [guid]::TryParse([string] $s, [ref] $g)
}

# Boucle jusqu'a une saisie valide. Le validateur rend $null si tout va bien,
# sinon le message d'erreur a afficher.
function DemanderValide($nomParametre, $valeur, $invite, [scriptblock] $valide, $aide, [switch] $Masque) {
  while ($true) {
    if (-not $valeur) {
      if (-not $script:Interactif) { Stop2 "Parametre manquant en mode non interactif : -$nomParametre" }
      $valeur = if ($Masque) { LireSecretMasque $invite } else { Read-Host $invite }
    }
    $probleme = & $valide $valeur
    if (-not $probleme) { return $valeur }
    if (-not $script:Interactif) { Stop2 "-$nomParametre : $probleme" }
    Avert $probleme
    if ($aide) { Info $aide }
    $valeur = $null
  }
}

# 'ok' si le tenant repond, 'invalide' si Microsoft ne le connait pas,
# 'reseau' si l'appel n'aboutit pas (hors ligne, proxy...).
function TesterTenantMicrosoft($tenant) {
  $url = "https://login.microsoftonline.com/$tenant/v2.0/.well-known/openid-configuration"
  try {
    $null = Invoke-RestMethod -Uri $url -TimeoutSec 15
    return 'ok'
  } catch {
    $reponse = $_.Exception.Response
    if ($reponse) {
      $code = 0
      try { $code = [int] $reponse.StatusCode } catch {}
      if ($code -ge 400 -and $code -lt 500) { return 'invalide' }
    }
    return 'reseau'
  }
}

# Rend @{ url = <normalisee> } ou @{ probleme = <message> }.
function NormaliserUrlPostgres($url, $nom) {
  $url = ([string] $url).Trim().Trim('"')
  if ($url -notmatch '^postgresql://') { return @{ probleme = "$nom doit commencer par postgresql:// (Supabase, Settings puis Database)." } }
  if ($url -match 'localhost|127\.0\.0\.1') { return @{ probleme = "$nom pointe sur ce poste : prendre l'adresse du projet Supabase, pas une adresse locale." } }
  if ($url -match '\{\{|\[YOUR|VOTRE-') { return @{ probleme = "$nom contient encore un morceau de gabarit non remplace." } }
  # pgbouncer=true ne sert a rien ici (adaptateur @prisma/adapter-pg) et a deja
  # cause des confusions : on le retire plutot que de le documenter.
  if ($url -match 'pgbouncer=true') {
    $url = $url -replace '&pgbouncer=true', '' -replace '\?pgbouncer=true&', '?' -replace '\?pgbouncer=true$', ''
  }
  # Le pilote pg de Node traite sslmode=require comme une verification stricte
  # et refuse le certificat Supabase (autorite privee) : uselibpqcompat=true
  # retablit le comportement de psql. La connexion reste chiffree.
  if ($url -notmatch 'uselibpqcompat=') {
    $url += $(if ($url -match '\?') { '&' } else { '?' }) + 'uselibpqcompat=true'
  }
  if ($url -notmatch 'sslmode=') { $url += '&sslmode=require' }
  return @{ url = $url }
}

Write-Host "=== Gestion Mails : configuration des comptes de service ===" -ForegroundColor White
Info "Construit le fichier .env d'une nouvelle organisation."
Info "Le detail de chaque etape : INSTALLATION-NOUVELLE-ORGANISATION.md"

# --- 0. Gabarit ---------------------------------------------------------------
if (-not $ModeleEnv) { $ModeleEnv = Voisin 'modele.env' }
if (-not $ModeleEnv -or -not (Test-Path $ModeleEnv)) {
  Stop2 "Gabarit modele.env introuvable a cote de ce script."
}

# --- 1. Mode ------------------------------------------------------------------
Titre '1/5 Mode de fonctionnement'
if (-not $Mode) {
  if (-not $script:Interactif) { Stop2 'Parametre manquant en mode non interactif : -Mode' }
  Write-Host "  1. Ce poste tout seul (defaut)" -ForegroundColor White
  Info "Base et Redis dans Docker, sur ce poste. Rien d'autre a creer."
  Write-Host "  2. Partage entre plusieurs postes" -ForegroundColor White
  Info "Base Supabase et Redis Upstash, a creer (paliers gratuits)."
  $r = Read-Host 'Votre choix [1-2]'
  $Mode = if ($r -eq '2') { 'partage' } else { 'local' }
}
Ok "Mode : $Mode"

# --- 2. Azure AD --------------------------------------------------------------
Titre '2/5 Application Azure AD (connexion a la boite Outlook)'

if ($script:Interactif -and (-not $MicrosoftClientId -or -not $MicrosoftTenantId -or -not $MicrosoftClientSecret)) {
  Info 'Marche a suivre (une seule fois, par un administrateur du tenant) :'
  Info '  1. https://portal.azure.com -> Microsoft Entra ID -> App registrations'
  Info '     -> New registration.'
  Info '  2. Nom libre (par ex. " Gestion Mails ") ; comptes de CET annuaire'
  Info '     uniquement (single tenant).'
  Info '  3. Redirect URI, plateforme Web, ajouter les TROIS adresses :'
  Info '       http://localhost:3000/api/auth/callback/microsoft'
  Info '       http://localhost:3000/api/outlook/linking/callback'
  Info '       http://localhost:3000/api/outlook/admin-consent/callback'
  Info '  4. API permissions -> Add a permission -> Microsoft Graph -> Delegated :'
  Info '       openid, profile, email, offline_access, User.Read,'
  Info '       Mail.ReadWrite, Mail.Send, MailboxSettings.ReadWrite'
  Info '     puis bouton " Grant admin consent ".'
  Info '  5. Certificates & secrets -> New client secret -> copier la colonne'
  Info '     VALUE (pas Secret ID) : elle n''est visible qu''une seule fois.'
  Info '  6. Overview : relever Application (client) ID et Directory (tenant) ID.'
  Write-Host ""
}

$MicrosoftClientId = DemanderValide 'MicrosoftClientId' $MicrosoftClientId 'Application (client) ID' {
  param($v)
  if (EstGuid $v) { return $null }
  return 'Un identifiant GUID est attendu (36 caracteres, tirets compris).'
} "Il se trouve sur la page Overview de l'application Azure."

$MicrosoftTenantId = DemanderValide 'MicrosoftTenantId' $MicrosoftTenantId 'Directory (tenant) ID' {
  param($v)
  if (-not ((EstGuid $v) -or ($v -in @('common', 'organizations')))) {
    return "Un GUID est attendu (ou 'common' pour une application multi-organisations)."
  }
  if (-not $SansValidationTenant) {
    $etat = TesterTenantMicrosoft $v
    if ($etat -eq 'invalide') { return 'Ce tenant est inconnu de Microsoft : verifier le Directory (tenant) ID.' }
    if ($etat -eq 'reseau') { Avert 'Pas de reseau : identifiant accepte sans verification en ligne.' }
  }
  return $null
} "Il se trouve sur la page Overview de l'application Azure."

$MicrosoftClientSecret = DemanderValide 'MicrosoftClientSecret' $MicrosoftClientSecret 'Client secret, colonne VALUE (saisie invisible)' {
  param($v)
  if (EstGuid $v) { return "Ceci est un identifiant (GUID), pas le secret : copier la colonne VALUE, pas Secret ID." }
  if (([string] $v).Length -lt 10) { return 'Valeur trop courte pour un secret client Azure.' }
  return $null
} "Si la Value n'est plus visible, creer un nouveau client secret." -Masque

Ok 'Application Azure AD renseignee'

# --- 3. Resend ----------------------------------------------------------------
Titre '3/5 Resend (envoi du recap par mail)'

if ($script:Interactif -and -not $ResendApiKey) {
  Info "Creer le compte sur https://resend.com AVEC L'ADRESSE DE LA BOITE SUIVIE :"
  Info "sans domaine verifie, le palier gratuit ne livre qu'au proprietaire du"
  Info 'compte Resend. Puis : API Keys -> Create API Key.'
  Write-Host ""
}

$ResendApiKey = DemanderValide 'ResendApiKey' $ResendApiKey 'Cle API Resend (saisie invisible)' {
  param($v)
  if ($v -notmatch '^re_') { return 'Une cle Resend commence par re_ .' }
  return $null
} 'Console Resend, menu API Keys.' -Masque

if (-not $ResendFromEmail) {
  $defautFrom = 'Gestion Mails <onboarding@resend.dev>'
  if ($script:Interactif) {
    $r = Read-Host "Expediteur du recap [Entree = $defautFrom]"
    $ResendFromEmail = if ($r) { $r } else { $defautFrom }
  } else {
    $ResendFromEmail = $defautFrom
  }
}
Ok "Resend renseigne (expediteur : $ResendFromEmail)"

# --- 4. Base et Redis ---------------------------------------------------------
Titre '4/5 Base de donnees et Redis'

if ($Mode -eq 'partage') {
  if ($script:Interactif -and (-not $DatabaseUrl -or -not $DirectUrl -or -not $UpstashRedisUrl -or -not $UpstashRedisToken)) {
    Info 'Supabase (https://supabase.com) : New project, puis bouton " Connect " :'
    Info '  - Transaction pooler (port 6543) -> DATABASE_URL'
    Info '  - Session pooler (port 5432)     -> DIRECT_URL'
    Info 'Upstash (https://upstash.com) : Create database (Redis), puis encadre'
    Info '  " REST API " : REST URL et REST TOKEN.'
    Write-Host ""
  }

  $DatabaseUrl = DemanderValide 'DatabaseUrl' $DatabaseUrl 'DATABASE_URL (pooler transaction, port 6543)' {
    param($v)
    $r = NormaliserUrlPostgres $v 'DATABASE_URL'
    if ($r.probleme) { return $r.probleme }
    return $null
  } 'Supabase -> Connect -> Transaction pooler.'
  $DatabaseUrl = (NormaliserUrlPostgres $DatabaseUrl 'DATABASE_URL').url

  $DirectUrl = DemanderValide 'DirectUrl' $DirectUrl 'DIRECT_URL (pooler session, port 5432)' {
    param($v)
    $r = NormaliserUrlPostgres $v 'DIRECT_URL'
    if ($r.probleme) { return $r.probleme }
    return $null
  } 'Supabase -> Connect -> Session pooler.'
  $DirectUrl = (NormaliserUrlPostgres $DirectUrl 'DIRECT_URL').url

  if ($DatabaseUrl -eq $DirectUrl) {
    Avert 'DATABASE_URL et DIRECT_URL sont identiques : les migrations passeront'
    Avert 'par le meme canal que le trafic courant. Cela fonctionne, mais les'
    Avert 'deux adresses de Supabase (6543 et 5432) sont recommandees.'
  }

  $UpstashRedisUrl = DemanderValide 'UpstashRedisUrl' $UpstashRedisUrl 'UPSTASH_REDIS_REST_URL' {
    param($v)
    if ($v -notmatch '^https://') { return "En mode partage, l'adresse Redis doit etre en https:// (encadre REST API d'Upstash)." }
    return $null
  } 'Console Upstash, encadre REST API.'

  $UpstashRedisToken = DemanderValide 'UpstashRedisToken' $UpstashRedisToken 'UPSTASH_REDIS_REST_TOKEN (saisie invisible)' {
    param($v)
    if (([string] $v).Length -lt 8) { return 'Jeton trop court : copier le REST TOKEN complet.' }
    return $null
  } 'Console Upstash, encadre REST API.' -Masque

  Ok 'Supabase et Upstash renseignes'
} else {
  Info 'Mode local : base et Redis vivront dans Docker sur ce poste.'
  Info "Rien a creer ; l'installeur demarrera les conteneurs."
  Ok 'Aucun service a renseigner'
}

# --- 5. Generation et ecriture ------------------------------------------------
Titre '5/5 Generation du fichier .env'

$secrets = @{
  'AUTH_SECRET'                      = NouveauSecretHex 32
  'EMAIL_ENCRYPT_SECRET'             = NouveauSecretHex 32
  'EMAIL_ENCRYPT_SALT'               = NouveauSecretHex 16
  'INTERNAL_API_KEY'                 = NouveauSecretHex 32
  'API_KEY_SALT'                     = NouveauSecretHex 32
  'CRON_SECRET'                      = NouveauSecretHex 32
  'MICROSOFT_WEBHOOK_CLIENT_STATE'   = NouveauSecretHex 32
  'GOOGLE_PUBSUB_VERIFICATION_TOKEN' = NouveauSecretHex 16
  'SRH_TOKEN_LOCAL'                  = NouveauSecretHex 32
}
Ok '9 secrets internes generes (jamais affiches, propres a cette organisation)'

$valeurs = @{
  '{{AUTH_SECRET}}'                      = $secrets['AUTH_SECRET']
  '{{EMAIL_ENCRYPT_SECRET}}'             = $secrets['EMAIL_ENCRYPT_SECRET']
  '{{EMAIL_ENCRYPT_SALT}}'               = $secrets['EMAIL_ENCRYPT_SALT']
  '{{INTERNAL_API_KEY}}'                 = $secrets['INTERNAL_API_KEY']
  '{{API_KEY_SALT}}'                     = $secrets['API_KEY_SALT']
  '{{CRON_SECRET}}'                      = $secrets['CRON_SECRET']
  '{{MICROSOFT_WEBHOOK_CLIENT_STATE}}'   = $secrets['MICROSOFT_WEBHOOK_CLIENT_STATE']
  '{{GOOGLE_PUBSUB_VERIFICATION_TOKEN}}' = $secrets['GOOGLE_PUBSUB_VERIFICATION_TOKEN']
  '{{SRH_TOKEN_LOCAL}}'                  = $secrets['SRH_TOKEN_LOCAL']
  '{{MICROSOFT_CLIENT_ID}}'              = $MicrosoftClientId
  '{{MICROSOFT_CLIENT_SECRET}}'          = '"' + $MicrosoftClientSecret + '"'
  '{{MICROSOFT_TENANT_ID}}'              = $MicrosoftTenantId
  '{{RESEND_API_KEY}}'                   = $ResendApiKey
  '{{RESEND_FROM_EMAIL}}'                = '"' + $ResendFromEmail + '"'
}
if ($Mode -eq 'partage') {
  $valeurs['{{SUPABASE_DATABASE_URL}}'] = '"' + $DatabaseUrl + '"'
  $valeurs['{{SUPABASE_DIRECT_URL}}']   = '"' + $DirectUrl + '"'
  $valeurs['{{UPSTASH_REDIS_URL}}']     = '"' + $UpstashRedisUrl + '"'
  $valeurs['{{UPSTASH_REDIS_TOKEN}}']   = '"' + $UpstashRedisToken + '"'
}

$lignes = @(Get-Content $ModeleEnv)

# Le gabarit est ecrit " partage actif ". En mode local : activer les lignes en
# reserve # MODE-LOCAL et RETIRER les lignes partage -- pas de reserve avec des
# {{...}} : une bascule ulterieure les activerait tels quels et casserait le
# poste. basculer-mode refuse proprement quand il n'y a aucune reserve.
$variablesBiMode = @('DATABASE_URL', 'DIRECT_URL', 'UPSTASH_REDIS_URL', 'UPSTASH_REDIS_TOKEN')
if ($Mode -eq 'local') {
  $lignes = @(foreach ($l in $lignes) {
    if ($l -like '# MODE-LOCAL *') { $l.Substring('# MODE-LOCAL '.Length) }
    elseif ($l -match '^\s*([A-Z0-9_]+)\s*=' -and $variablesBiMode -contains $Matches[1]) { }
    else { $l }
  })
}

# Substitution litterale (String.Replace : aucun caractere special interprete).
$texte = $lignes -join [Environment]::NewLine
foreach ($cle in $valeurs.Keys) { $texte = $texte.Replace($cle, [string] $valeurs[$cle]) }

if ($texte -match '\{\{[A-Z0-9_]+\}\}') {
  Stop2 "Des valeurs manquent (marqueur $($Matches[0]) residuel) : rien n'a ete ecrit."
}

if (-not (Test-Path $Sortie)) { New-Item -ItemType Directory -Force -Path $Sortie | Out-Null }
$cible = Join-Path $Sortie '.env'

if ((Test-Path $cible) -and -not $Force) {
  if (-not $script:Interactif) { Stop2 "$cible existe deja : relancer avec -Force pour le remplacer." }
  Avert "$cible existe deja."
  $r = Read-Host 'Le remplacer ? (o/N)'
  if ($r -notmatch '^(o|O|oui|y|Y)$') { Info "Annule, rien n'a ete ecrit."; exit 0 }
}
if (Test-Path $cible) { Copy-Item $cible "$cible.avant-regeneration" -Force }

[System.IO.File]::WriteAllText($cible, $texte + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
Ok "Fichier ecrit : $cible"

# --- Recapitulatif (sans aucun secret) -----------------------------------------
Write-Host ""
Write-Host "=== Configuration terminee ===" -ForegroundColor White
Info "Mode : $Mode  |  Tenant : $MicrosoftTenantId  |  Expediteur : $ResendFromEmail"
Info 'Ce fichier contient des secrets : ne pas le diffuser, ne pas le committer.'
Write-Host ""
Write-Host 'La suite :' -ForegroundColor White
Write-Host '  1. Double-cliquer installer.cmd : le .env sera trouve automatiquement.'
Write-Host "  2. Le choix du fournisseur d'IA est propose pendant l'installation."
Write-Host '  3. Premier acces : " Sign in with Microsoft ". Si le consentement'
Write-Host '     administrateur manque encore, ouvrir :'
Write-Host '     http://localhost:3000/login/microsoft-admin-consent'
Write-Host ""
exit 0
