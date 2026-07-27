<#
.SYNOPSIS
  Desactive ou desinstalle " Gestion Mails " sur ce poste.

.DESCRIPTION
  Trois niveaux, du plus reversible au plus radical. Par defaut on se contente
  de DESACTIVER : rien n'est supprime, tout est reactivable en une commande.

  Ce script ne touche JAMAIS aux mails. Les traces laissees dans Outlook
  (brouillons non envoyes, categories creees) ne sont retirees que sur demande
  explicite, et l'operation est alors decrite avant d'etre lancee.

.EXAMPLE
  .\uninstall.ps1                      # desactive seulement
  .\uninstall.ps1 -Desinstaller        # + tache, raccourci, conteneurs, depot
  .\uninstall.ps1 -Desinstaller -AvecDocker -AvecNode
#>
[CmdletBinding()]
param(
  [string] $RepoPath = (Join-Path $env:USERPROFILE 'dev\inbox-zero'),
  [string] $NomTache = 'InboxZero Recap 7h',
  # Supprime l'application : tache, raccourci, conteneurs, depot, journaux.
  [switch] $Desinstaller,
  # Logiciels partages : JAMAIS par defaut, ils servent probablement ailleurs.
  [switch] $AvecDocker,
  [switch] $AvecNode,
  [switch] $AvecPnpm,
  # Ne pose aucune question (usage automatise).
  [switch] $SansConfirmation
)

$ErrorActionPreference = 'Stop'
$script:Faits = @()

function Etape($t) { Write-Host "`n>>> $t" -ForegroundColor Cyan }
function Ok($t) { $script:Faits += $t; Write-Host "    [fait] $t" -ForegroundColor Green }
function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Rate($t, $d) { Write-Host "    [echec] $t" -ForegroundColor Red; if ($d) { Write-Host "    $d" -ForegroundColor Red } }

$logDir = Join-Path $env:LOCALAPPDATA 'GestionMails\logs'
$raccourci = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gestion Mails.lnk'

# --- Ce qui va etre fait, avant de le faire -----------------------------------
Write-Host "=== Gestion Mails : $(if ($Desinstaller) { 'DESINSTALLATION' } else { 'DESACTIVATION' }) ===" -ForegroundColor White
Write-Host ""
Write-Host "Seront traites :" -ForegroundColor White
Write-Host "  - tache planifiee " $NomTache "  : $(if ($Desinstaller) { 'SUPPRIMEE' } else { 'desactivee' })"
Write-Host "  - serveur local sur le port 3000  : arrete"
if ($Desinstaller) {
  Write-Host "  - raccourci Bureau                : supprime"
  Write-Host "  - conteneurs et volumes Docker    : supprimes (docker compose down -v)"
  Write-Host "  - journaux ($logDir) : supprimes"
  Write-Host "  - depot ($RepoPath) : supprime"
}
foreach ($o in @(
  @{ actif = $AvecDocker; texte = 'Docker Desktop : DESINSTALLE' },
  @{ actif = $AvecNode;   texte = 'Node / fnm : DESINSTALLES' },
  @{ actif = $AvecPnpm;   texte = 'pnpm : DESINSTALLE' }
)) { if ($o.actif) { Write-Host "  - $($o.texte)" -ForegroundColor Yellow } }
Write-Host ""
Write-Host "Ne seront PAS touches : tes mails, tes brouillons, tes categories Outlook," -ForegroundColor White
Write-Host "et le fichier .env dans OneDrive." -ForegroundColor White
Write-Host ""

if (-not $SansConfirmation) {
  $reponse = Read-Host "Continuer ? (o/N)"
  if ($reponse -notmatch '^(o|O|oui|y|Y)$') { Write-Host "Annule." ; exit 0 }
}

# --- 1. Tache planifiee -------------------------------------------------------
Etape 'Tache planifiee'
try {
  $tache = Get-ScheduledTask -TaskName $NomTache -ErrorAction Stop
  if ($Desinstaller) {
    Unregister-ScheduledTask -TaskName $NomTache -Confirm:$false
    Ok "Tache " $NomTache " supprimee"
  } else {
    Disable-ScheduledTask -TaskName $NomTache | Out-Null
    Ok "Tache " $NomTache " desactivee (Enable-ScheduledTask pour la reactiver)"
  }
} catch {
  Info "Aucune tache " $NomTache " sur ce poste."
}

# --- 2. Serveur ---------------------------------------------------------------
Etape 'Serveur local'
$connexion = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($connexion) {
  # On remonte jusqu'au cmd racine : tuer le seul processus qui ecoute ne suffit
  # pas, le superviseur de Next relance aussitot son worker.
  $courant = $connexion[0].OwningProcess
  $racine = $courant
  for ($i = 0; $i -lt 6; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$courant" -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $racine = $p.ProcessId
    if ($p.Name -eq 'cmd.exe') { break }
    $courant = $p.ParentProcessId
  }
  function Stop-Arbre($id) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue |
      ForEach-Object { Stop-Arbre $_.ProcessId }
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  }
  Stop-Arbre $racine
  Start-Sleep -Seconds 2
  Ok 'Serveur arrete'
} else {
  Info 'Aucun serveur en cours.'
}

if (-not $Desinstaller) {
  Write-Host "`n=== Desactivation terminee ===" -ForegroundColor White
  Write-Host "Pour tout remettre en marche :" -ForegroundColor White
  Write-Host "  Enable-ScheduledTask -TaskName '$NomTache'"
  Write-Host ""
  $script:Faits | ForEach-Object { Write-Host "  - $_" }
  exit 0
}

# --- 3. Raccourci -------------------------------------------------------------
Etape 'Raccourci Bureau'
if (Test-Path $raccourci) {
  Remove-Item -LiteralPath $raccourci -Force
  Ok 'Raccourci supprime'
} else { Info 'Aucun raccourci.' }

# --- 4. Conteneurs ------------------------------------------------------------
Etape 'Conteneurs Docker'
$compose = Join-Path $RepoPath 'docker-compose.dev.yml'
if ((Test-Path $compose) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  docker compose -f $compose down -v 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Ok 'Conteneurs et volumes supprimes' }
  else { Rate 'docker compose down' "Code $LASTEXITCODE - les conteneurs sont peut-etre deja absents." }
} else { Info 'Docker absent ou depot introuvable.' }

# --- 5. Journaux --------------------------------------------------------------
Etape 'Journaux'
if (Test-Path $logDir) {
  Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
  Ok "Journaux supprimes ($logDir)"
} else { Info 'Aucun journal.' }

# --- 6. Depot -----------------------------------------------------------------
Etape 'Depot'
if (Test-Path $RepoPath) {
  # node_modules contient des dizaines de milliers de fichiers : Remove-Item
  # peut echouer sur les chemins longs, on retente via robocopy si besoin.
  try {
    Remove-Item -LiteralPath $RepoPath -Recurse -Force -ErrorAction Stop
  } catch {
    $vide = Join-Path $env:TEMP "gm-vide-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $vide | Out-Null
    robocopy $vide $RepoPath /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Remove-Item -LiteralPath $RepoPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vide -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $RepoPath) { Rate 'Suppression du depot' 'Des fichiers resistent, verifier a la main.' }
  else { Ok "Depot supprime ($RepoPath)" }
} else { Info 'Depot deja absent.' }

# --- 7. Logiciels partages (uniquement sur demande) ---------------------------
if ($AvecDocker -or $AvecNode -or $AvecPnpm) {
  Etape 'Logiciels partages'
  Info 'Ces logiciels servent peut-etre a d autres travaux.'

  if ($AvecPnpm -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    npm uninstall -g pnpm 2>&1 | Out-Null
    Ok 'pnpm desinstalle'
  }
  if ($AvecNode -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    winget uninstall --id Schniz.fnm --silent 2>&1 | Out-Null
    Ok 'fnm desinstalle (les versions de Node restent dans %APPDATA%\fnm)'
  }
  if ($AvecDocker -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    winget uninstall --id Docker.DockerDesktop --silent 2>&1 | Out-Null
    Ok 'Docker Desktop desinstalle'
  }
}

Write-Host "`n=== Desinstallation terminee ===" -ForegroundColor White
$script:Faits | ForEach-Object { Write-Host "  - $_" }
Write-Host ""
Write-Host "Restent en place, volontairement :" -ForegroundColor White
Write-Host "  - tes mails, brouillons et categories Outlook"
Write-Host "  - le fichier .env dans OneDrive (secrets)"
Write-Host "  - la base de donnees hebergee, le cas echeant"
Write-Host ""
