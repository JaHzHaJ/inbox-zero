<#
.SYNOPSIS
  Installe " Gestion Mails " (fork Inbox Zero) sur un poste Windows.

.DESCRIPTION
  Idempotent : peut etre relance autant de fois que necessaire, il met alors
  simplement le depot a jour. S'arrete au premier echec avec un message clair.

  Les secrets ne transitent JAMAIS par GitHub (le fork est public) : le fichier
  .env est recupere depuis le dossier OneDrive professionnel, deja synchronise
  sur les postes.

.EXAMPLE
  .\install.ps1
  .\install.ps1 -Mode partage
  .\install.ps1 -RepoPath D:\dev\inbox-zero -SkipSmokeTest

.NOTES
  Deux modes de fonctionnement :
    local   - base et Redis dans Docker, sur ce poste. Autonome, ne depend
              d'aucun service exterieur, mais ne se partage pas.
    partage - base Supabase et Redis Upstash. Plusieurs postes se partagent
              une seule boite : un seul recap par jour, historique commun.
  Sans -Mode, la question est posee.
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'partage')]
  [string] $Mode,
  [string] $RepoPath = (Join-Path $env:USERPROFILE 'dev\inbox-zero'),
  [string] $RepoUrl = 'https://github.com/JaHzHaJ/inbox-zero.git',
  [string] $Branch = 'phase2-recap',
  [string] $SecretsPath,
  [string] $NodeVersion = '24.18.0',
  [ValidateSet('claude-cli', 'cle-api', 'plus-tard')]
  [string] $Ia,
  [switch] $SkipTask,
  [switch] $SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
$script:Etapes = @()

function Etape($libelle) { Write-Host "`n>>> $libelle" -ForegroundColor Cyan }
function Ok($libelle) {
  $script:Etapes += [pscustomobject]@{ Etat = 'OK'; Etape = $libelle }
  Write-Host "    [OK] $libelle" -ForegroundColor Green
}
function Info($texte) { Write-Host "    $texte" -ForegroundColor DarkGray }
function Echec($libelle, $detail) {
  $script:Etapes += [pscustomobject]@{ Etat = 'ECHEC'; Etape = $libelle }
  Write-Host "    [ECHEC] $libelle" -ForegroundColor Red
  if ($detail) { Write-Host "    $detail" -ForegroundColor Red }
  Resume
  exit 1
}
function Resume {
  Write-Host "`n================ RESUME ================"
  foreach ($e in $script:Etapes) {
    $couleur = if ($e.Etat -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host ("  {0,-6} {1}" -f $e.Etat, $e.Etape) -ForegroundColor $couleur
  }
}
function Existe($commande) {
  $null -ne (Get-Command $commande -ErrorAction SilentlyContinue)
}
function Winget($id, $nom) {
  if (-not (Existe 'winget')) {
    Echec "Installation de $nom" "winget est absent : installer $nom manuellement, puis relancer."
  }
  Info "Installation de $nom via winget (peut demander une confirmation)..."
  winget install --id $id -e --source winget --accept-package-agreements --accept-source-agreements
}

function Demander($question, $choix, $defaut) {
  # Choix numerote plutot que saisie libre : sur un poste neuf, l'utilisateur
  # ne connait pas notre vocabulaire interne.
  Write-Host ""
  Write-Host $question -ForegroundColor White
  for ($i = 0; $i -lt $choix.Count; $i++) {
    $marque = if ($choix[$i].valeur -eq $defaut) { ' (defaut)' } else { '' }
    Write-Host ("  {0}. {1}{2}" -f ($i + 1), $choix[$i].titre, $marque) -ForegroundColor White
    Write-Host ("     {0}" -f $choix[$i].detail) -ForegroundColor DarkGray
  }
  while ($true) {
    $r = Read-Host "Votre choix [1-$($choix.Count)]"
    if (-not $r) { return $defaut }
    $n = 0
    if ([int]::TryParse($r, [ref] $n) -and $n -ge 1 -and $n -le $choix.Count) {
      return $choix[$n - 1].valeur
    }
    Write-Host "  Reponse non comprise." -ForegroundColor Yellow
  }
}

Write-Host "=== Installation de Gestion Mails ===" -ForegroundColor White
Info "Depot cible : $RepoPath"

# --- 0. Mode -----------------------------------------------------------------
if (-not $Mode) {
  $Mode = Demander 'Comment ce poste doit-il fonctionner ?' @(
    @{ valeur = 'partage'; titre = 'Partage avec un autre poste';
       detail = 'Base et verrous heberges (Supabase, Upstash). Les postes voient les memes regles et le meme historique, un seul recap part le matin. Pas de Docker.' },
    @{ valeur = 'local'; titre = 'Ce poste tout seul';
       detail = 'Base et Redis dans Docker, ici. Autonome et gratuit, mais rien ne se partage avec un autre poste.' }
  ) 'partage'
}
Ok "Mode : $Mode"

# --- 1. Prerequis ------------------------------------------------------------
Etape '1/11 Prerequis (git, Node, pnpm)'

if (-not (Existe 'git')) { Winget 'Git.Git' 'Git' }
if (-not (Existe 'git')) {
  Echec 'Git' "Git reste introuvable. Fermer/rouvrir le terminal puis relancer."
}
Ok "Git : $((git --version) -replace 'git version ','')"

# Node 24 : fnm l'installe dans %APPDATA%, il n'est pas toujours dans le PATH.
$fnmNode = Join-Path $env:APPDATA "fnm\node-versions\v$NodeVersion\installation"
if (Test-Path (Join-Path $fnmNode 'node.exe')) {
  $env:Path = "$fnmNode;$env:Path"
}

$versionNode = if (Existe 'node') { (node -v) -replace '^v', '' } else { $null }
$majeure = if ($versionNode) { [int]($versionNode -split '\.')[0] } else { 0 }

if ($majeure -lt 24) {
  if (-not (Existe 'fnm')) { Winget 'Schniz.fnm' 'fnm' }
  if (-not (Existe 'fnm')) {
    Echec 'Node 24' "fnm reste introuvable. Fermer/rouvrir le terminal puis relancer."
  }
  Info "Installation de Node $NodeVersion via fnm..."
  fnm install $NodeVersion
  if (Test-Path (Join-Path $fnmNode 'node.exe')) { $env:Path = "$fnmNode;$env:Path" }
  $versionNode = if (Existe 'node') { (node -v) -replace '^v', '' } else { $null }
  $majeure = if ($versionNode) { [int]($versionNode -split '\.')[0] } else { 0 }
}

if ($majeure -lt 24) { Echec 'Node 24' "Node $NodeVersion requis, trouve : $versionNode" }
Ok "Node : $versionNode"

if (-not (Existe 'pnpm')) {
  Info 'Installation de pnpm...'
  npm install -g pnpm
}
if (-not (Existe 'pnpm')) { Echec 'pnpm' 'pnpm reste introuvable.' }
Ok "pnpm : $(pnpm --version)"

# --- 2. Docker (mode local uniquement) ---------------------------------------
Etape '2/11 Docker'

if ($Mode -eq 'local') {
  if (-not (Existe 'docker')) { Winget 'Docker.DockerDesktop' 'Docker Desktop' }
  if (-not (Existe 'docker')) {
    Echec 'Docker Desktop' @"
Docker reste introuvable. En mode local, la base de donnees et Redis tournent
dans Docker : il est indispensable. Fermer/rouvrir la session puis relancer,
ou choisir le mode partage (-Mode partage), qui n'a besoin de rien de tout ca.
"@
  }
  Ok 'Docker present'
} else {
  Info 'Mode partage : Docker inutile sur ce poste.'
}

# --- 3. Depot ----------------------------------------------------------------
Etape '3/11 Depot'

if (Test-Path (Join-Path $RepoPath '.git')) {
  Info 'Depot deja present, mise a jour...'
  git -C $RepoPath fetch origin $Branch
  git -C $RepoPath checkout $Branch
  git -C $RepoPath pull --ff-only origin $Branch
  Ok "Depot mis a jour sur $Branch"
} else {
  $parent = Split-Path $RepoPath -Parent
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Info "Clonage de $RepoUrl (quelques minutes)..."
  git clone --branch $Branch $RepoUrl $RepoPath
  Ok "Depot clone sur $Branch"
}

# OneDrive synchronise les fichiers a la demande : un depot pose dedans casse
# les liens symboliques de node_modules et ralentit tout.
if ($RepoPath -like "*OneDrive*") {
  Info 'ATTENTION : le depot est dans OneDrive. Deconseille (node_modules synchronise).'
}

# --- 4. Secrets --------------------------------------------------------------
Etape '4/11 Fichier .env (secrets)'

# Un .env par mode : ils different par 4 variables (base et Redis). Le nom
# suffixe est essaye en premier, le .env generique reste accepte pour les kits
# fabriques avant l'arrivee des deux modes.
$suffixe = if ($Mode -eq 'local') { '.env.local-docker' } else { '.env.partage' }

if (-not $SecretsPath) {
  # Priorite aux fichiers poses A COTE de ce script : c'est ce qui rend le kit
  # ZIP autonome, decompressable n'importe ou. OneDrive n'est que le repli.
  $baseOneDrive = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { $env:OneDrive }
  $candidats = @(
    (Join-Path $PSScriptRoot $suffixe),
    (Join-Path $PSScriptRoot '.env'),
    (Join-Path $baseOneDrive "Gestion Mails\$suffixe"),
    (Join-Path $baseOneDrive 'Gestion Mails\.env')
  )
  foreach ($c in $candidats) {
    if (Test-Path $c) { $SecretsPath = $c; break }
  }
  if (-not $SecretsPath) { $SecretsPath = $candidats[-1] }
}

$cible = Join-Path $RepoPath 'apps\web\.env'

if (Test-Path $SecretsPath) {
  Copy-Item $SecretsPath $cible -Force
  Ok "Secrets copies depuis $SecretsPath"
} elseif (Test-Path $cible) {
  Info 'Source OneDrive absente, mais un .env existe deja : on le conserve.'
  Ok 'Secrets deja en place'
} else {
  Echec 'Fichier .env' @"
Introuvable : $SecretsPath
Verifier que OneDrive a fini de synchroniser le dossier " Gestion Mails ",
ou passer le chemin explicitement : .\install.ps1 -SecretsPath <chemin\.env>
"@
}

foreach ($cle in @('DATABASE_URL', 'CRON_SECRET', 'AUTH_SECRET', 'EMAIL_ENCRYPT_SECRET')) {
  if (-not (Select-String -Path $cible -Pattern "^$cle=.+" -Quiet)) {
    Echec 'Fichier .env' "La variable $cle est absente ou vide dans $cible"
  }
}

# Le .env correspond-il au mode demande ? Une incoherence ici ne se verrait
# sinon qu'au premier recap manque, plusieurs jours plus tard.
# L'ancrage ^ evite de confondre avec la ligne "# MODE-LOCAL DATABASE_URL=..."
# laissee en commentaire pour permettre le retour arriere.
$baseEstLocale = Select-String -Path $cible -Pattern '^DATABASE_URL=.*(localhost|127\.0\.0\.1)' -Quiet
if ($Mode -eq 'partage' -and $baseEstLocale) {
  Echec 'Fichier .env' @"
Le mode partage a ete demande, mais DATABASE_URL pointe sur ce poste
(localhost). Ce .env est celui du mode local : avec lui, ce poste aurait sa
propre base et ne partagerait rien.
Recuperer le fichier .env.partage dans le dossier OneDrive " Gestion Mails ".
"@
}
if ($Mode -eq 'local' -and -not $baseEstLocale) {
  Echec 'Fichier .env' @"
Le mode local a ete demande, mais DATABASE_URL pointe sur une base hebergee.
Recuperer le fichier .env.local-docker, ou relancer avec -Mode partage.
"@
}
if ($Mode -eq 'partage' -and -not (Select-String -Path $cible -Pattern '^UPSTASH_REDIS_URL=.*https://' -Quiet)) {
  Echec 'Fichier .env' @"
En mode partage, UPSTASH_REDIS_URL doit etre une adresse https.
Une adresse locale signifierait que les postes ne partagent pas leurs verrous :
ils traiteraient les memes mails chacun de leur cote, en double.
"@
}
Ok "Variables essentielles presentes et coherentes avec le mode $Mode"

# --- 5. Dependances ----------------------------------------------------------
Etape '5/11 Dependances'

Push-Location $RepoPath
try {
  # Piege connu : pnpm peut avoir enable-global-virtual-store=true en config
  # utilisateur alors que ce depot est en disposition classique.
  Info 'pnpm install (plusieurs minutes au premier passage)...'
  pnpm install --config.enable-global-virtual-store=false
  if ($LASTEXITCODE -ne 0) { Echec 'pnpm install' "Code de sortie $LASTEXITCODE" }
  Ok 'Dependances installees'
} finally {
  Pop-Location
}

# --- 6. Client Prisma --------------------------------------------------------
Etape '6/11 Client Prisma'

Push-Location (Join-Path $RepoPath 'apps\web')
try {
  # Pas de " migrate " : la base est partagee entre les postes, elle fait foi.
  & .\node_modules\.bin\prisma.CMD generate
  if ($LASTEXITCODE -ne 0) { Echec 'prisma generate' "Code de sortie $LASTEXITCODE" }
  Ok 'Client Prisma genere'
} finally {
  Pop-Location
}

# --- 7. Fournisseur d'IA -----------------------------------------------------
Etape "7/11 Fournisseur d'intelligence artificielle"

# Delegue a un script autonome : le meme sert plus tard, via
# .claude\configurer-ia.cmd, sans avoir a tout reinstaller.
$argsIa = @('-RepoPath', $RepoPath)
if ($Ia) { $argsIa += @('-Choix', $Ia) }
& (Join-Path $PSScriptRoot 'configurer-ia.ps1') @argsIa
if ($LASTEXITCODE -ne 0) {
  # Pas un echec bloquant : le poste s'installe, mais sans classement des mails.
  Info "Fournisseur d'IA non operationnel. L'installation continue ;"
  Info "relancer .claude\configurer-ia.cmd quand ce sera regle."
}

# --- 8. Verification des services --------------------------------------------
Etape '8/11 Verification des services'

if ($Mode -eq 'local') {
  Info 'Demarrage des conteneurs avant verification...'
  & (Join-Path $PSScriptRoot 'ensure-stack.cmd') | Out-Null
}

Push-Location (Join-Path $RepoPath 'apps\web')
try {
  & node 'scripts\verifier-services.mjs'
  if ($LASTEXITCODE -ne 0) {
    Echec 'Verification des services' @"
La base ou Redis ne repondent pas (details ci-dessus).
Rien ne sert de continuer : sans eux l'application ne peut pas fonctionner.
"@
  }
  Ok 'Base de donnees et Redis operationnels'
} finally {
  Pop-Location
}

# --- 9. Raccourci Bureau -----------------------------------------------------
Etape '9/11 Raccourci Bureau'

$raccourci = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gestion Mails.lnk'
$shell = New-Object -ComObject WScript.Shell
$lien = $shell.CreateShortcut($raccourci)
$lien.TargetPath = Join-Path $RepoPath '.claude\ouvrir-gestion-mails.cmd'
$lien.WorkingDirectory = $RepoPath
$lien.Description = 'Ouvrir le portail Gestion Mails'
$lien.Save()
Ok "Raccourci cree : $raccourci"

# --- 7. Tache planifiee ------------------------------------------------------
Etape '10/11 Tache planifiee " InboxZero Recap 7h "'

if ($SkipTask) {
  Info 'Ignoree (-SkipTask)'
} else {
  $nomTache = 'InboxZero Recap 7h'
  $commande = Join-Path $RepoPath '.claude\digest-cron.cmd'
  $utilisateur = "$env:USERDOMAIN\$env:USERNAME"
  $debut = (Get-Date -Format 'yyyy-MM-dd') + 'T07:00:00'

  # XML plutot que New-ScheduledTask* : seul moyen de fixer exactement la
  # repetition (PT30M sur PT11H) et de laisser StopAtDurationEnd a false, qui
  # sinon tuerait un rattrapage en cours.
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Envoi du recap quotidien Inbox Zero (jours ouvres 7h, rattrapage si poste eteint)</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$utilisateur</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <RestartOnFailure>
      <Count>3</Count>
      <Interval>PT15M</Interval>
    </RestartOnFailure>
    <StartWhenAvailable>true</StartWhenAvailable>
    <WakeToRun>true</WakeToRun>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$debut</StartBoundary>
      <Repetition>
        <Interval>PT30M</Interval>
        <Duration>PT11H</Duration>
      </Repetition>
      <ScheduleByWeek>
        <WeeksInterval>1</WeeksInterval>
        <DaysOfWeek><Monday /><Tuesday /><Wednesday /><Thursday /><Friday /></DaysOfWeek>
      </ScheduleByWeek>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$commande</Command>
    </Exec>
  </Actions>
</Task>
"@

  try { Unregister-ScheduledTask -TaskName $nomTache -Confirm:$false -ErrorAction Stop } catch {}
  Register-ScheduledTask -TaskName $nomTache -Xml $xml | Out-Null

  $verif = Get-ScheduledTask -TaskName $nomTache
  if ($verif.Triggers[0].Repetition.Duration -ne 'PT11H') {
    Echec 'Tache planifiee' 'La repetition ne s est pas appliquee.'
  }
  Ok "Tache creee (lun-ven 7h, reessais toutes les 30 min jusqu a 18h)"

  $reveil = powercfg /q SCHEME_CURRENT SUB_SLEEP RTCWAKE 2>&1 | Out-String
  if ($reveil -match '0x00000000') {
    Info 'NOTE : les minuteurs de reveil sont desactives dans le plan d alimentation.'
    Info '       WakeToRun restera sans effet. Pour l activer (invite ADMINISTRATEUR) :'
    Info '       powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1'
    Info '       powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1'
    Info '       powercfg /setactive SCHEME_CURRENT'
  }
}

# --- 8. Test de fumee --------------------------------------------------------
Etape '11/11 Test de fumee'

if ($SkipSmokeTest) {
  Info 'Ignore (-SkipSmokeTest)'
} else {
  Info 'Demarrage de la pile puis appel de http://localhost:3000/login ...'
  & (Join-Path $RepoPath '.claude\ensure-stack.cmd')
  if ($LASTEXITCODE -ne 0) {
    Echec 'Test de fumee' "ensure-stack a renvoye $LASTEXITCODE. Voir .claude\ensure-stack.log"
  }
  $reponse = try {
    (Invoke-WebRequest -Uri 'http://localhost:3000/login' -UseBasicParsing -TimeoutSec 30).StatusCode
  } catch { 0 }
  if ($reponse -ne 200) { Echec 'Test de fumee' "http://localhost:3000/login a repondu $reponse" }
  Ok 'Application joignable sur http://localhost:3000'
}

Resume
Write-Host @"

Installation terminee.

  - Raccourci " Gestion Mails " sur le Bureau.
  - Recap automatique du lundi au vendredi a 7h (reessais jusqu a 18h).
  - Premier acces : cliquer " Sign in with Microsoft " une fois.

"@ -ForegroundColor White
