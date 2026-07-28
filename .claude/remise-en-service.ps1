<#
.SYNOPSIS
  Remet " Gestion Mails " en marche apres une longue interruption.

.DESCRIPTION
  Repond a " je reviens de conges " ou " plus rien ne marche " sans qu'il faille
  comprendre ce qui s'est passe. Le script nomme la panne au lieu d'afficher une
  erreur de connexion illisible, puis propose la reparation qui correspond.

  Le cas de loin le plus frequent apres trois semaines d'arret : le palier
  gratuit de Supabase met le projet EN PAUSE au bout de 7 jours sans activite.
  Les donnees sont alors intactes et il n'y a RIEN a restaurer : un clic dans la
  console suffit. Le script insiste sur ce point, car restaurer par reflexe
  ferait perdre tout ce qui s'est passe depuis la derniere sauvegarde.

.EXAMPLE
  .\remise-en-service.ps1
#>
[CmdletBinding()]
param(
  [string] $RepoPath,
  [switch] $SansConfirmation
)

$ErrorActionPreference = 'Stop'

if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$web = Join-Path $RepoPath 'apps\web'
$fichierEnv = Join-Path $web '.env'
$dossierSauvegardes = Join-Path $env:LOCALAPPDATA 'GestionMails\backups'

# Ce script vit a deux endroits : dans .claude\ du depot, et a plat dans le kit
# decompresse. Ses voisins se cherchent donc dans les deux dispositions -- sans
# quoi l'installation sur un poste neuf casserait en plein milieu.
function Voisin($nom) {
  $aCote = Join-Path $PSScriptRoot $nom
  if (Test-Path $aCote) { return $aCote }
  $dansDepot = Join-Path $RepoPath ".claude\$nom"
  if (Test-Path $dansDepot) { return $dansDepot }
  return $null
}

function Titre($t) { Write-Host "`n>>> $t" -ForegroundColor Cyan }
function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Avert($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }
function Rate($t) { Write-Host "    [ECHEC] $t" -ForegroundColor Red }

Write-Host "=== Gestion Mails : remise en service ===" -ForegroundColor White

if (-not (Test-Path $fichierEnv)) {
  Rate "Fichier de configuration introuvable : $fichierEnv"
  Info "L'application n'est pas installee ici. Lancer installer.cmd."
  exit 1
}

$mode = if (Select-String -Path $fichierEnv -Pattern '^DATABASE_URL=.*(localhost|127\.0\.0\.1)' -Quiet) { 'local' } else { 'partage' }
Info "Mode de ce poste : $mode"

# --- 1. Diagnostic ------------------------------------------------------------
Titre '1/4 Diagnostic'

function Diagnostiquer {
  Push-Location $web
  try {
    $sortie = & node 'scripts\verifier-services.mjs' 2>&1 | Out-String
    $script:CodeDiag = $LASTEXITCODE
    return $sortie
  } finally { Pop-Location }
}

$rapport = Diagnostiquer
Write-Host $rapport

if ($CodeDiag -eq 0) {
  Ok 'Tous les services repondent : rien de casse de ce cote.'
} else {
  # Le message du diagnostic nomme deja la panne ; on choisit la reparation.
  if ($rapport -match 'EN PAUSE') {
    Titre '2/4 Projet mis en pause par l hebergeur'
    Info "C'est le comportement normal du palier gratuit apres 7 jours sans"
    Info "activite. VOS DONNEES SONT INTACTES : il n'y a rien a restaurer."
    Write-Host ""
    Info 'A faire maintenant :'
    Info '  1. ouvrir https://supabase.com/dashboard'
    Info '  2. choisir le projet " Gestion Mails "'
    Info '  3. cliquer " Restore project " et patienter 2 a 5 minutes'
    Write-Host ""
    Start-Process 'https://supabase.com/dashboard' -ErrorAction SilentlyContinue

    Info "J'attends que la base reponde (verification toutes les 30 secondes)..."
    $reveille = $false
    for ($i = 1; $i -le 20; $i++) {
      Start-Sleep -Seconds 30
      $null = Diagnostiquer
      if ($CodeDiag -eq 0) { $reveille = $true; break }
      Info "  toujours en pause... ($i/20)"
    }
    if ($reveille) { Ok 'Le projet est reveille et la base repond.' }
    else {
      Rate "Le projet ne repond toujours pas apres 10 minutes."
      Info 'Relancer ce script une fois le reveil termine.'
      exit 1
    }
  }
  elseif ($rapport -match 'VIDE|tables sont absentes') {
    Titre '2/4 Base vide : restauration necessaire'
    $sauvegardes = @(Get-ChildItem -Path $dossierSauvegardes -Filter 'base-*.zip' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
    if ($sauvegardes.Count -eq 0) {
      Rate "Aucune sauvegarde dans $dossierSauvegardes"
      Info "Verifier si l'autre poste en possede."
      exit 1
    }
    Write-Host ""
    Info 'Sauvegardes disponibles :'
    for ($i = 0; $i -lt $sauvegardes.Count; $i++) {
      $s = $sauvegardes[$i]
      $marque = if ($i -eq 0) { ' (la plus recente, par defaut)' } else { '' }
      Info ("  {0}. {1}  {2:yyyy-MM-dd HH:mm}  {3} Ko{4}" -f ($i + 1), $s.Name, $s.LastWriteTime, [math]::Round($s.Length / 1KB), $marque)
    }
    $r = Read-Host "Laquelle restaurer ? [1-$($sauvegardes.Count)]"
    $index = 0
    if ($r -and [int]::TryParse($r, [ref] $index) -and $index -ge 1 -and $index -le $sauvegardes.Count) {
      $choisie = $sauvegardes[$index - 1]
    } else { $choisie = $sauvegardes[0] }

    $rb = Voisin 'restaurer-base.ps1'
    if (-not $rb) { Rate 'restaurer-base.ps1 introuvable.'; exit 1 }
    & $rb -Archive $choisie.FullName -RepoPath $RepoPath
    if ($LASTEXITCODE -ne 0) { Rate 'La restauration a echoue.'; exit 1 }
    Ok 'Base restauree.'
  }
  elseif ($rapport -match 'Docker|conteneurs') {
    Titre '2/4 Services locaux arretes'
    Info 'Demarrage de Docker et des conteneurs...'
    $es = Voisin 'ensure-stack.cmd'; if ($es) { & $es | Out-Null }
    $null = Diagnostiquer
    if ($CodeDiag -ne 0) { Rate 'Les services locaux ne repondent toujours pas.'; exit 1 }
    Ok 'Services locaux repartis.'
  }
  else {
    Titre '2/4 Panne non automatisable'
    Rate "Le diagnostic ci-dessus decrit le probleme et la marche a suivre."
    Info 'Corriger, puis relancer ce script.'
    exit 1
  }
}

# --- 3. Serveur ---------------------------------------------------------------
Titre '3/4 Redemarrage de l application'
# Toujours arreter avant de relancer : un serveur deja en cours garde en memoire
# sa connexion a l'ancienne base et continuerait de l'utiliser sans rien dire.
# C'est exactement ce qui s'est produit le 28/07 : le recap est parti depuis la
# base d'avant la migration parce que le serveur n'avait pas ete redemarre.
$as = Voisin 'arreter-serveur.ps1'; if ($as) { & $as }
$es = Voisin 'ensure-stack.cmd'; if ($es) { & $es | Out-Null }
try {
  $code = (Invoke-WebRequest -Uri 'http://localhost:3000/login' -UseBasicParsing -TimeoutSec 60).StatusCode
} catch { $code = 0 }
if ($code -ne 200) { Rate "L'application ne repond pas (code $code)."; exit 1 }
Ok 'Application demarree.'

# --- 4. Etat du recap ---------------------------------------------------------
Titre '4/4 Etat du recap'
$tache = Get-ScheduledTask -TaskName 'InboxZero Recap 7h' -ErrorAction SilentlyContinue
if (-not $tache) {
  Avert "La tache planifiee est absente : le recap ne partira pas tout seul."
  Info 'Relancer installer.cmd pour la recreer.'
} elseif ($tache.State -eq 'Disabled') {
  Avert 'La tache planifiee est desactivee.'
  Info "Pour la reactiver : Enable-ScheduledTask -TaskName 'InboxZero Recap 7h'"
} else {
  $info = Get-ScheduledTaskInfo -TaskName 'InboxZero Recap 7h'
  Ok "Tache active. Prochaine execution : $($info.NextRunTime)"
}

Write-Host ""
Write-Host "=== Remise en service terminee ===" -ForegroundColor White
Info 'Le prochain recap partira a la prochaine echeance (jours ouvres, 7h).'
exit 0
