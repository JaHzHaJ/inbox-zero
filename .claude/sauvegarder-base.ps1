<#
.SYNOPSIS
  Sauvegarde la base de donnees de " Gestion Mails " sur ce poste.

.DESCRIPTION
  Pourquoi c'est indispensable en mode partage : le palier gratuit de Supabase
  ne fait AUCUNE sauvegarde, et met meme le projet en pause apres 7 jours sans
  activite. La seule copie de secours est celle que nous fabriquons ici.

  Chaque sauvegarde est DATEE et les 8 dernieres sont conservees (environ deux
  mois d'historique). Ecraser un fichier unique chaque semaine serait un piege :
  une corruption passee inapercue sept jours detruirait la seule copie saine.

  L'outil pg_dump est cherche dans cet ordre :
    1. une installation PostgreSQL du poste (winget, EDB, Scoop...)
    2. Docker, via l'image officielle postgres:17
  S'il n'y en a aucun, le script le DIT au lieu de produire un fichier de
  qualite incertaine. Un seul poste suffit a assurer les sauvegardes.

.EXAMPLE
  .\sauvegarder-base.ps1
  .\sauvegarder-base.ps1 -Silencieux      # pour la tache planifiee
#>
[CmdletBinding()]
param(
  [string] $RepoPath,
  [int] $Conserver = 8,
  # Ne sauvegarde que si la derniere date de plus de $TousLesJours jours.
  # C'est l'age des fichiers qui fait foi, pas un marqueur separe : rien a
  # resynchroniser, et un poste eteint le jour prevu rattrape au reveil.
  [switch] $SiNecessaire,
  [int] $TousLesJours = 7,
  [switch] $Silencieux
)

$ErrorActionPreference = 'Stop'

if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$fichierEnv = Join-Path $RepoPath 'apps\web\.env'
$dossier = Join-Path $env:LOCALAPPDATA 'GestionMails\backups'
$journal = Join-Path $env:LOCALAPPDATA 'GestionMails\logs\sauvegarde.log'

function Dire($t, $couleur = 'DarkGray') {
  if (-not $Silencieux) { Write-Host "    $t" -ForegroundColor $couleur }
  $ligne = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t
  Add-Content -Path $journal -Value $ligne -Encoding utf8
}

New-Item -ItemType Directory -Force -Path $dossier | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $journal -Parent) | Out-Null

if (-not (Test-Path $fichierEnv)) { Dire "Fichier .env introuvable : $fichierEnv" 'Red'; exit 1 }

if ($SiNecessaire) {
  $derniere = Get-ChildItem -Path $dossier -Filter 'base-*.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($derniere -and $derniere.LastWriteTime -gt (Get-Date).AddDays(-$TousLesJours)) {
    $jours = [math]::Round(((Get-Date) - $derniere.LastWriteTime).TotalDays, 1)
    Dire "Derniere sauvegarde il y a $jours jour(s) : rien a faire."
    exit 0
  }
}

# On sauvegarde par DIRECT_URL : en mode partage c'est le pooler " session ",
# qui supporte les operations longues, contrairement au pooler " transaction "
# de DATABASE_URL qui coupe les gros exports.
$url = $null
foreach ($cle in @('DIRECT_URL', 'DATABASE_URL')) {
  $m = Select-String -Path $fichierEnv -Pattern "^$cle=`"?([^`"]+)`"?" | Select-Object -First 1
  if ($m) { $url = $m.Matches[0].Groups[1].Value.Trim(); break }
}
if (-not $url) { Dire 'Aucune URL de base dans le .env' 'Red'; exit 1 }

$estLocale = $url -match 'localhost|127\.0\.0\.1'
$mode = if ($estLocale) { 'local' } else { 'partage' }

# pg_dump n'accepte pas les parametres propres aux pilotes applicatifs.
$urlPropre = $url -replace 'uselibpqcompat=true&?', '' -replace '[?&]$', ''

$horodatage = Get-Date -Format 'yyyy-MM-dd'
$sql = Join-Path $dossier "base-$horodatage.sql"
$zip = Join-Path $dossier "base-$horodatage.zip"

Dire "Sauvegarde de la base ($mode) vers $zip"

# --- Trouver pg_dump ----------------------------------------------------------
$pgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue).Source
if (-not $pgDump) {
  foreach ($v in @('18', '17', '16')) {
    $c = "$env:ProgramFiles\PostgreSQL\$v\bin\pg_dump.exe"
    if (Test-Path $c) { $pgDump = $c; break }
  }
}
$viaDocker = $false
if (-not $pgDump) {
  docker info 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { $viaDocker = $true }
}

if (-not $pgDump -and -not $viaDocker) {
  Dire 'Aucun moyen de sauvegarder sur ce poste.' 'Red'
  Dire 'Il faut soit PostgreSQL installe (winget install PostgreSQL.PostgreSQL.17),' 'Red'
  Dire 'soit Docker Desktop. Un seul poste suffit a assurer les sauvegardes :' 'Red'
  Dire "verifier que l'autre poste les fait." 'Red'
  exit 2
}

# --- Dump ---------------------------------------------------------------------
# Pas de --clean : ses instructions " DROP TRIGGER IF EXISTS ... ON <table> "
# echouent quand la table n'existe pas encore, c'est-a-dire exactement dans le
# cas ou une sauvegarde sert : restaurer sur une base vide.
# --schema=public : sans lui, le dump embarque aussi les schemas internes de
# l'hebergeur (auth, storage, realtime...) qui ne nous appartiennent pas et ne
# se restaurent nulle part. Mesure faite : 102 tables au lieu de nos 68.
# --file plutot qu'une redirection : sous PowerShell 5.1, " > " et
# " Set-Content -Encoding utf8 " ajoutent un BOM en tete, et psql echoue alors
# des la premiere instruction du fichier.
$optionsDump = @('--schema=public', '--no-owner', '--no-acl')
try {
  if ($viaDocker) {
    $nomFichier = Split-Path $sql -Leaf
    if ($estLocale) {
      # Depuis un conteneur, " localhost " designe le conteneur lui-meme.
      $urlConteneur = $urlPropre -replace 'localhost|127\.0\.0\.1', 'host.docker.internal'
      docker run --rm --add-host=host.docker.internal:host-gateway -v "${dossier}:/out" postgres:17 `
        pg_dump "$urlConteneur" @optionsDump --file="/out/$nomFichier"
    } else {
      docker run --rm -v "${dossier}:/out" postgres:17 `
        pg_dump "$urlPropre" @optionsDump --file="/out/$nomFichier"
    }
    if ($LASTEXITCODE -ne 0) { throw "pg_dump a renvoye $LASTEXITCODE" }
  } else {
    & $pgDump "$urlPropre" @optionsDump --file="$sql"
    if ($LASTEXITCODE -ne 0) { throw "pg_dump a renvoye $LASTEXITCODE" }
  }
} catch {
  Dire "Echec du dump : $($_.Exception.Message)" 'Red'
  if (Test-Path $sql) { Remove-Item $sql -Force }
  exit 1
}

# --- Extensions ---------------------------------------------------------------
# pg_dump n'ecrit AUCUN " CREATE EXTENSION " quand on filtre par schema : il les
# considere comme exterieures. Or ce schema en utilise (btree_gist, exigee par
# une contrainte d'exclusion posee par une migration). Restaurer sur un
# PostgreSQL neuf echouait donc net -- decouvert en rejouant vraiment une
# restauration, jamais un test unitaire ne l'aurait vu.
# On prefixe le fichier avec ce qu'il faut : la sauvegarde reste un fichier
# unique et autonome.
function Executer($requete) {
  if ($viaDocker) {
    if ($estLocale) {
      $u = $urlPropre -replace 'localhost|127\.0\.0\.1', 'host.docker.internal'
      docker run --rm --add-host=host.docker.internal:host-gateway postgres:17 psql "$u" -tAc $requete 2>$null
    } else {
      docker run --rm postgres:17 psql "$urlPropre" -tAc $requete 2>$null
    }
  } else {
    & (Join-Path (Split-Path $pgDump -Parent) 'psql.exe') "$urlPropre" -tAc $requete 2>$null
  }
}

if (Test-Path $sql) {
  $extensions = @(Executer "select extname from pg_extension e join pg_namespace n on n.oid = e.extnamespace where n.nspname = 'public' and extname <> 'plpgsql';" |
    Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  if ($extensions.Count -gt 0) {
    $entete = @(
      '-- Extensions requises, ajoutees par sauvegarder-base.ps1 :',
      '-- pg_dump ne les inclut pas quand on filtre par schema.'
    ) + ($extensions | ForEach-Object { "CREATE EXTENSION IF NOT EXISTS `"$_`";" }) + @('')
    $contenu = ($entete -join "`n") + [System.IO.File]::ReadAllText($sql)
    # Sans BOM : psql echouerait des la premiere instruction.
    [System.IO.File]::WriteAllText($sql, $contenu, (New-Object System.Text.UTF8Encoding $false))
    Dire "Extensions ajoutees a la sauvegarde : $($extensions -join ', ')"
  }
}

if (-not (Test-Path $sql) -or (Get-Item $sql).Length -lt 10240) {
  # Un dump de quelques octets est un echec deguise : mieux vaut aucune
  # sauvegarde qu'une sauvegarde vide en laquelle on aurait confiance.
  Dire 'Le fichier produit est trop petit : sauvegarde consideree comme ratee.' 'Red'
  if (Test-Path $sql) { Remove-Item $sql -Force }
  exit 1
}

$tables = (Select-String -Path $sql -Pattern '^CREATE TABLE ' -AllMatches).Count
Compress-Archive -Path $sql -DestinationPath $zip -Force -CompressionLevel Optimal
Remove-Item $sql -Force
$taille = [math]::Round((Get-Item $zip).Length / 1KB)
Dire "Sauvegarde ecrite : $tables tables, $taille Ko" 'Green'

# --- Rotation -----------------------------------------------------------------
$anciennes = Get-ChildItem -Path $dossier -Filter 'base-*.zip' |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip $Conserver
foreach ($f in $anciennes) {
  Remove-Item $f.FullName -Force
  Dire "Ancienne sauvegarde retiree : $($f.Name)"
}
$restantes = (Get-ChildItem -Path $dossier -Filter 'base-*.zip').Count
Dire "$restantes sauvegarde(s) conservee(s) dans $dossier" 'Green'
exit 0
