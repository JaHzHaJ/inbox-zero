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

$logDir = Join-Path $env:LOCALAPPDATA 'GestionMails'
$raccourci = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Gestion Mails.lnk'

# Le mode n'est pas demande : il est DEDUIT du .env. Un desinstalleur doit
# regarder ce qui est la, pas supposer ce qu'on a voulu installer. C'est aussi
# pourquoi il n'en existe qu'un seul : lancer le mauvais des deux serait le
# principal risque.
$fichierEnv = Join-Path $RepoPath 'apps\web\.env'
$mode = 'inconnu'
if (Test-Path $fichierEnv) {
  $mode = if (Select-String -Path $fichierEnv -Pattern '^DATABASE_URL=.*(localhost|127\.0\.0\.1)' -Quiet) { 'local' } else { 'partage' }
}

# --- Ce qui va etre fait, avant de le faire -----------------------------------
Write-Host "=== Gestion Mails : $(if ($Desinstaller) { 'DESINSTALLATION' } else { 'DESACTIVATION' }) ===" -ForegroundColor White
Write-Host ""
Write-Host "Mode detecte sur ce poste : $mode" -ForegroundColor White
Write-Host ""
Write-Host "Seront traites :" -ForegroundColor White
Write-Host "  - tache planifiee " $NomTache "  : $(if ($Desinstaller) { 'SUPPRIMEE' } else { 'desactivee' })"
Write-Host "  - serveur local sur le port 3000  : arrete"
if ($Desinstaller) {
  Write-Host "  - raccourci Bureau                : supprime"
  if ($mode -eq 'local') {
    Write-Host "  - base et Redis (conteneurs Docker) : SUPPRIMES avec leurs donnees"
  } else {
    Write-Host "  - anciens conteneurs Docker, s il en reste : supprimes"
  }
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
if ($mode -eq 'partage') {
  Write-Host ""
  Write-Host "Ce poste est en mode PARTAGE : la base Supabase et Redis Upstash ne sont" -ForegroundColor Green
  Write-Host "PAS touches. Les regles, l'historique et le recap restent intacts, et" -ForegroundColor Green
  Write-Host "l'autre poste continue de fonctionner normalement." -ForegroundColor Green
}
if ($mode -eq 'local' -and $Desinstaller) {
  Write-Host ""
  Write-Host "Ce poste est en mode LOCAL : la base est ICI, dans Docker. La supprimer" -ForegroundColor Yellow
  Write-Host "efface les regles et tout l'historique du recap, definitivement." -ForegroundColor Yellow
  Write-Host "Pour les conserver, faire d'abord une sauvegarde : sauvegarder-base.cmd" -ForegroundColor Yellow
}
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
    Ok "Tache '$NomTache' supprimee"
  } else {
    Disable-ScheduledTask -TaskName $NomTache | Out-Null
    Ok "Tache '$NomTache' desactivee (Enable-ScheduledTask pour la reactiver)"
  }
} catch {
  Info "Aucune tache '$NomTache' sur ce poste."
}

# --- 2. Serveur ---------------------------------------------------------------
Etape 'Serveur local'
# Logique partagee avec basculer-mode : un seul endroit a corriger, et les trois
# pieges connus (superviseur qui relance, remontee limitee aux node.exe, port
# occupe par un autre programme) y sont traites une fois pour toutes.
& (Join-Path $PSScriptRoot 'arreter-serveur.ps1')
if ($LASTEXITCODE -eq 0) { Ok 'Serveur arrete (ou deja a l arret)' }
else { Rate 'Arret du serveur' 'Le port 3000 repond encore.' }

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
  # Sortir du dossier avant de le supprimer : Windows verrouille le repertoire
  # courant de chaque programme, la racine du depot resisterait.
  Set-Location $env:TEMP
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
