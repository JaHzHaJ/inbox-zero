<#
.SYNOPSIS
  Verifie l'installation de " Gestion Mails " sur ce poste, dans un mode donne.

.DESCRIPTION
  " Les deux modes a egalite " ne tient que si les verifier coute une commande,
  pas une heure de manipulations : personne ne refait a la main une batterie de
  controles a chaque modification.

  Ce script rejoue donc la meme batterie quel que soit le mode :
    - base joignable et coherente
    - Redis joignable, y compris ses verrous (script Lua)
    - serveur qui repond
    - tache planifiee en place
    - sauvegarde presente et lisible

  Verifier le mode INACTIF ne bascule RIEN : le script fabrique une
  configuration temporaire a partir des lignes en reserve du .env et la teste de
  cote. La production n'est pas touchee.

.EXAMPLE
  .\verifier-installation.ps1                  # le mode en service
  .\verifier-installation.ps1 -Mode local      # l'autre mode, sans rien basculer
  .\verifier-installation.ps1 -Tous            # les deux
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'partage')]
  [string] $Mode,
  [switch] $Tous,
  [string] $RepoPath
)

$ErrorActionPreference = 'Stop'

if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$web = Join-Path $RepoPath 'apps\web'
$fichierEnv = Join-Path $web '.env'

$script:Echecs = 0
function Titre($t) { Write-Host "`n>>> $t" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Rate($t) { $script:Echecs++; Write-Host "    [ECHEC] $t" -ForegroundColor Red }

if (-not (Test-Path $fichierEnv)) { Rate "Fichier .env introuvable : $fichierEnv"; exit 1 }

$lignes = @(Get-Content $fichierEnv)
function ModeDe($lignes) {
  foreach ($l in $lignes) {
    if ($l -match '^DATABASE_URL=') {
      return $(if ($l -match 'localhost|127\.0\.0\.1|@db:') { 'local' } else { 'partage' })
    }
  }
  return 'inconnu'
}
$modeCourant = ModeDe $lignes

$aVerifier = if ($Tous) { @('local', 'partage') } elseif ($Mode) { @($Mode) } else { @($modeCourant) }

Write-Host "=== Verification de l'installation ===" -ForegroundColor White
Info "Mode en service : $modeCourant"

# --- Controles independants du mode -------------------------------------------
Titre 'Environnement du poste'

$tache = Get-ScheduledTask -TaskName 'InboxZero Recap 7h' -ErrorAction SilentlyContinue
if (-not $tache) { Rate "Tache planifiee absente : le recap ne partira pas tout seul." }
elseif ($tache.State -eq 'Disabled') { Rate 'Tache planifiee desactivee.' }
else {
  $infoTache = Get-ScheduledTaskInfo -TaskName 'InboxZero Recap 7h'
  Ok "Tache planifiee active, prochaine execution : $($infoTache.NextRunTime)"
}

$dossierSauvegardes = Join-Path $env:LOCALAPPDATA 'GestionMails\backups'
$sauvegardes = @(Get-ChildItem -Path $dossierSauvegardes -Filter 'base-*.zip' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending)
if ($sauvegardes.Count -eq 0) {
  # Sans sauvegarde, un projet mis en pause puis supprime par l'hebergeur est
  # une perte seche : le palier gratuit n'en fait aucune de son cote.
  Rate "Aucune sauvegarde dans $dossierSauvegardes"
} else {
  $age = [math]::Round(((Get-Date) - $sauvegardes[0].LastWriteTime).TotalDays, 1)
  if ($age -gt 8) { Rate "Derniere sauvegarde vieille de $age jours (attendu : moins de 8)." }
  else { Ok "$($sauvegardes.Count) sauvegarde(s), la plus recente il y a $age jour(s)" }
  # Lisible ? Une archive corrompue ne se decouvre pas le jour ou elle sert.
  # Windows PowerShell 5.1 ne charge pas cette assembly de lui-meme.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($sauvegardes[0].FullName)
    $entree = $zip.Entries | Where-Object { $_.Name -like '*.sql' } | Select-Object -First 1
    $taille = if ($entree) { $entree.Length } else { 0 }
    $zip.Dispose()
    if ($taille -lt 10240) { Rate 'La derniere sauvegarde ne contient pas de dump exploitable.' }
    else { Ok "Sauvegarde lisible ($([math]::Round($taille / 1KB)) Ko une fois decompressee)" }
  } catch { Rate "Sauvegarde illisible : $($_.Exception.Message)" }
}

# --- Controles par mode -------------------------------------------------------
foreach ($m in $aVerifier) {
  Titre "Services en mode $m"

  $envATester = $fichierEnv
  $temporaire = $null

  if ($m -ne $modeCourant) {
    # Fabriquer la configuration de l'autre mode a partir des lignes en reserve,
    # dans un fichier temporaire. Le .env en service n'est pas modifie.
    $marqueur = "# MODE-$($m.ToUpper()) "
    $reserve = @($lignes | Where-Object { $_ -like "$marqueur*" })
    if ($reserve.Count -eq 0) {
      Rate "Aucune ligne en reserve pour le mode $m dans le .env : mode non verifiable."
      continue
    }
    $variables = @('DATABASE_URL', 'DIRECT_URL', 'UPSTASH_REDIS_URL', 'UPSTASH_REDIS_TOKEN')
    $contenu = foreach ($l in $lignes) {
      if ($l -like "$marqueur*") { $l.Substring($marqueur.Length) }
      elseif ($l -match '^\s*([A-Z0-9_]+)\s*=' -and $variables -contains $Matches[1]) { }
      else { $l }
    }
    $temporaire = Join-Path $env:TEMP "gm-verif-$($m)-$([guid]::NewGuid().ToString('N')).env"
    [System.IO.File]::WriteAllLines($temporaire, [string[]] $contenu, (New-Object System.Text.UTF8Encoding $false))
    $envATester = $temporaire
    Info "Configuration $m reconstituee de cote (production intacte)"
  }

  try {
    if ($m -eq 'local') {
      # docker compose directement, PAS ensure-stack : celui-ci deduit le mode du
      # .env EN SERVICE et sauterait Docker quand la production est en partage.
      # C'est justement le cas ou l'on veut verifier le mode local.
      if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Rate 'Docker absent : le mode local ne peut pas fonctionner sur ce poste.'
        continue
      }
      Info 'Demarrage des conteneurs...'
      $compose = Join-Path $RepoPath 'docker-compose.dev.yml'
      $ancien = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try { docker compose -f $compose up -d 2>&1 | Out-Null } finally { $ErrorActionPreference = $ancien }
      # Postgres accepte les connexions quelques secondes apres le demarrage du
      # conteneur : sans cette attente le controle echoue a tort.
      for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        $etat = docker inspect -f '{{.State.Health.Status}}' inbox-zero-dev-db 2>$null
        if ($etat -eq 'healthy') { break }
      }
    }

    Push-Location $web
    try {
      & node 'scripts\verifier-services.mjs' --env $envATester
      if ($LASTEXITCODE -ne 0) { Rate "Les services ne repondent pas en mode $m." }
      else { Ok "Services operationnels en mode $m" }
    } finally { Pop-Location }
  } finally {
    if ($temporaire) { Remove-Item $temporaire -Force -ErrorAction SilentlyContinue }
  }
}

# --- Serveur ------------------------------------------------------------------
Titre 'Application'
try {
  $code = (Invoke-WebRequest -Uri 'http://localhost:3000/login' -UseBasicParsing -TimeoutSec 30).StatusCode
} catch { $code = 0 }
if ($code -eq 200) { Ok 'Application joignable sur http://localhost:3000' }
else { Info "Application non demarree (code $code) - lancer .claude\ensure-stack.cmd si besoin" }

Write-Host ""
if ($script:Echecs -eq 0) {
  Write-Host "=== Tout est conforme ===" -ForegroundColor Green
  exit 0
}
Write-Host "=== $($script:Echecs) point(s) a corriger ===" -ForegroundColor Red
exit 1
