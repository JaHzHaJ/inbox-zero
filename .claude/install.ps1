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
  .\install.ps1 -RepoPath D:\dev\inbox-zero -SkipSmokeTest
#>
[CmdletBinding()]
param(
  [string] $RepoPath = (Join-Path $env:USERPROFILE 'dev\inbox-zero'),
  [string] $RepoUrl = 'https://github.com/JaHzHaJ/inbox-zero.git',
  [string] $Branch = 'phase2-recap',
  [string] $SecretsPath,
  [string] $NodeVersion = '24.18.0',
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

Write-Host "=== Installation de Gestion Mails ===" -ForegroundColor White
Info "Depot cible : $RepoPath"

# --- 1. Prerequis ------------------------------------------------------------
Etape '1/8 Prerequis (git, Node, pnpm)'

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

# --- 2. Depot ----------------------------------------------------------------
Etape '2/8 Depot'

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

# --- 3. Secrets --------------------------------------------------------------
Etape '3/8 Fichier .env (secrets)'

if (-not $SecretsPath) {
  # Priorite au .env pose A COTE de ce script : c'est ce qui rend le kit ZIP
  # autonome, decompressable n'importe ou. OneDrive n'est que le repli.
  $voisin = Join-Path $PSScriptRoot '.env'
  if (Test-Path $voisin) {
    $SecretsPath = $voisin
  } else {
    $baseOneDrive = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { $env:OneDrive }
    $SecretsPath = Join-Path $baseOneDrive 'Gestion Mails\.env'
  }
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
Ok 'Variables essentielles presentes'

# --- 4. Dependances ----------------------------------------------------------
Etape '4/8 Dependances'

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

# --- 5. Client Prisma --------------------------------------------------------
Etape '5/8 Client Prisma'

Push-Location (Join-Path $RepoPath 'apps\web')
try {
  # Pas de " migrate " : la base est partagee entre les postes, elle fait foi.
  & .\node_modules\.bin\prisma.CMD generate
  if ($LASTEXITCODE -ne 0) { Echec 'prisma generate' "Code de sortie $LASTEXITCODE" }
  Ok 'Client Prisma genere'
} finally {
  Pop-Location
}

# --- 6. Raccourci Bureau -----------------------------------------------------
Etape '6/8 Raccourci Bureau'

$raccourci = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gestion Mails.lnk'
$shell = New-Object -ComObject WScript.Shell
$lien = $shell.CreateShortcut($raccourci)
$lien.TargetPath = Join-Path $RepoPath '.claude\ouvrir-gestion-mails.cmd'
$lien.WorkingDirectory = $RepoPath
$lien.Description = 'Ouvrir le portail Gestion Mails'
$lien.Save()
Ok "Raccourci cree : $raccourci"

# --- 7. Tache planifiee ------------------------------------------------------
Etape '7/8 Tache planifiee " InboxZero Recap 7h "'

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
Etape '8/8 Test de fumee'

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
