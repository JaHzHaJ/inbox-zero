<#
.SYNOPSIS
  Restaure une sauvegarde de la base de donnees.

.DESCRIPTION
  Contrepartie exacte de sauvegarder-base.ps1 : ce qui sauvegarde sait
  restaurer, avec les memes outils.

  Garde-fou : si la base cible contient deja des donnees, les deux etats sont
  affiches et une confirmation explicite est exigee. Jamais d'ecrasement
  silencieux -- restaurer par reflexe sur une base saine ferait perdre tout ce
  qui s'est passe depuis la sauvegarde.

.EXAMPLE
  .\restaurer-base.ps1                                  # la plus recente
  .\restaurer-base.ps1 -Archive C:\...\base-2026-07-28.zip
#>
[CmdletBinding()]
param(
  [string] $Archive,
  [string] $RepoPath,
  [switch] $SansConfirmation
)

$ErrorActionPreference = 'Stop'

if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$fichierEnv = Join-Path $RepoPath 'apps\web\.env'
$dossier = Join-Path $env:LOCALAPPDATA 'GestionMails\backups'

function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Rate($t) { Write-Host "    [ECHEC] $t" -ForegroundColor Red }

if (-not (Test-Path $fichierEnv)) { Rate "Fichier .env introuvable : $fichierEnv"; exit 1 }

if (-not $Archive) {
  $derniere = Get-ChildItem -Path $dossier -Filter 'base-*.zip' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $derniere) { Rate "Aucune sauvegarde dans $dossier"; exit 1 }
  $Archive = $derniere.FullName
}
if (-not (Test-Path $Archive)) { Rate "Archive introuvable : $Archive"; exit 1 }
Info "Sauvegarde : $Archive"

# On restaure par DIRECT_URL : en mode partage c'est le pooler " session ",
# le seul qui supporte un script long. Le pooler " transaction " le couperait.
$url = $null
foreach ($cle in @('DIRECT_URL', 'DATABASE_URL')) {
  $m = Select-String -Path $fichierEnv -Pattern "^$cle=`"?([^`"]+)`"?" | Select-Object -First 1
  if ($m) { $url = $m.Matches[0].Groups[1].Value.Trim(); break }
}
if (-not $url) { Rate 'Aucune URL de base dans le .env'; exit 1 }
$estLocale = $url -match 'localhost|127\.0\.0\.1'
$urlPropre = $url -replace 'uselibpqcompat=true&?', '' -replace '[?&]$', ''

# --- Outils -------------------------------------------------------------------
$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) {
  foreach ($v in @('18', '17', '16')) {
    $c = "$env:ProgramFiles\PostgreSQL\$v\bin\psql.exe"
    if (Test-Path $c) { $psql = $c; break }
  }
}
$viaDocker = $false
if (-not $psql) {
  docker info 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { $viaDocker = $true }
}
if (-not $psql -and -not $viaDocker) {
  Rate 'Ni PostgreSQL ni Docker sur ce poste : restauration impossible.'
  Info 'Installer PostgreSQL (winget install PostgreSQL.PostgreSQL.17) ou Docker.'
  exit 1
}

function Executer($requete) {
  # La requete passe par l'ENTREE STANDARD, jamais en argument : les guillemets
  # doubles qui entourent les noms de tables ( "EmailAccount" ) sont manges en
  # traversant PowerShell puis docker, et PostgreSQL replie alors le nom en
  # minuscules -- " relation emailaccount does not exist ".
  $fichier = Join-Path $env:TEMP "gm-req-$([guid]::NewGuid().ToString('N')).sql"
  # client_min_messages : sans cela psql ecrit ses NOTICE ( " drop cascades
  # to... " ) sur la sortie d'erreur. PowerShell 5.1 les transforme alors en
  # erreurs bloquantes, et le script s'arrete sur un simple message d'information.
  # Concatenation, PAS d'interpolation : le SQL contient " DO $$ ... $$ ", et
  # dans une chaine a guillemets doubles PowerShell remplacerait $$ par la
  # valeur d'une variable automatique. Le bloc partait alors vide, sans erreur.
  $contenu = 'SET client_min_messages = warning;' + [Environment]::NewLine + $requete
  [System.IO.File]::WriteAllText($fichier, $contenu, (New-Object System.Text.UTF8Encoding $false))
  $ancien = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      if ($estLocale) {
        $u = $urlPropre -replace 'localhost|127\.0\.0\.1', 'host.docker.internal'
        Get-Content $fichier -Raw | docker run --rm -i --add-host=host.docker.internal:host-gateway postgres:17 psql "$u" -tA -q 2>$null
      } else {
        Get-Content $fichier -Raw | docker run --rm -i postgres:17 psql "$urlPropre" -tA -q 2>$null
      }
    } else { & $psql "$urlPropre" -tA -q -f $fichier 2>$null }
  } finally {
    $ErrorActionPreference = $ancien
    Remove-Item $fichier -Force -ErrorAction SilentlyContinue
  }
}

# --- Garde-fou ----------------------------------------------------------------
$existant = (Executer "select coalesce((select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'),0);" | Select-Object -First 1)
$nbTables = 0; [void][int]::TryParse(($existant -replace '\s', ''), [ref] $nbTables)

if ($nbTables -gt 0 -and -not $SansConfirmation) {
  Write-Host ""
  Write-Host "    ATTENTION : la base cible n'est PAS vide." -ForegroundColor Yellow
  Info "Elle contient deja $nbTables table(s)."
  $etat = Executer "select coalesce((select count(*)::text from `"EmailAccount`"),'?')||' compte(s), '||coalesce((select count(*)::text from `"Rule`"),'?')||' regle(s), '||coalesce((select count(*)::text from `"DigestItem`"),'?')||' element(s) de recap';"
  if ($etat) { Info "Contenu actuel : $($etat -join '')" }
  Write-Host ""
  Write-Host "    La restauration REMPLACE ce contenu par celui de la sauvegarde." -ForegroundColor Yellow
  Write-Host "    Tout ce qui s'est passe depuis sera perdu." -ForegroundColor Yellow
  Write-Host ""
  $r = Read-Host "    Taper REMPLACER en majuscules pour confirmer"
  if ($r -cne 'REMPLACER') { Info 'Annule, rien n a ete modifie.'; exit 0 }
}

# --- Extraction ---------------------------------------------------------------
$travail = Join-Path $env:TEMP "gm-restauration-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Force -Path $travail | Out-Null
try {
  Expand-Archive -Path $Archive -DestinationPath $travail -Force
  $sql = Get-ChildItem -Path $travail -Filter '*.sql' | Select-Object -First 1
  if (-not $sql) { Rate "L'archive ne contient aucun fichier .sql"; exit 1 }

  # Le schema public existe sur toute base PostgreSQL : le recreer echouerait,
  # et sur un hebergeur il porte des droits qui ne nous appartiennent pas.
  $pret = Join-Path $travail 'pret.sql'
  Get-Content $sql.FullName | Where-Object {
    $_ -notmatch '^(CREATE SCHEMA public;|COMMENT ON SCHEMA public IS)'
  } | Set-Content -Path $pret -Encoding utf8

  if ($nbTables -gt 0) {
    # Le dump ne supprime rien avant de creer (volontairement : ses instructions
    # de suppression echouent sur une base vide, c'est-a-dire dans le cas ou une
    # sauvegarde sert le plus souvent). On vide donc nous-memes, puisque le
    # remplacement a ete confirme.
    # Filtre sur le PROPRIETAIRE : un hebergeur pose ses propres tables dans le
    # meme schema, et les supprimer casserait d'autres applications. Verifie en
    # conditions reelles -- le projet Supabase voisin hebergeait une autre base.
    Info 'Suppression du contenu precedent (nos objets uniquement)...'
    $null = Executer @'
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'public' AND tableowner = current_user LOOP
    EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', r.tablename);
  END LOOP;
  -- Exclure les objets appartenant a une EXTENSION : PostgreSQL refuse de les
  -- supprimer un par un, et ce refus avorte tout le bloc -- annulant au passage
  -- les suppressions deja faites. C'est le cas des dizaines de fonctions de
  -- btree_gist, qui appartiennent au meme role que nos tables.
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proowner = current_user::regrole
             AND NOT EXISTS (SELECT 1 FROM pg_depend d
                             WHERE d.objid = p.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.sig);
  END LOOP;
  FOR r IN SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE n.nspname = 'public' AND t.typtype = 'e' AND t.typowner = current_user::regrole
             AND NOT EXISTS (SELECT 1 FROM pg_depend d
                             WHERE d.objid = t.oid AND d.deptype = 'e') LOOP
    EXECUTE format('DROP TYPE IF EXISTS public.%I CASCADE', r.typname);
  END LOOP;
END $$;
'@
  }

  Info 'Restauration en cours (quelques minutes)...'
  # Meme precaution : psql parle sur la sortie d'erreur meme quand tout va bien.
  # Le verdict est donne par le code de sortie, pas par la presence de messages.
  $ancienEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      $u = if ($estLocale) { $urlPropre -replace 'localhost|127\.0\.0\.1', 'host.docker.internal' } else { $urlPropre }
      $params = @('run', '--rm', '-i')
      if ($estLocale) { $params += @('--add-host=host.docker.internal:host-gateway') }
      $params += @('postgres:17', 'psql', $u, '-v', 'ON_ERROR_STOP=1', '-q')
      Get-Content $pret -Raw | & docker @params
    } else {
      & $psql "$urlPropre" -v ON_ERROR_STOP=1 -q -f $pret
    }
  } finally { $ErrorActionPreference = $ancienEAP }
  if ($LASTEXITCODE -ne 0) { Rate "psql a renvoye $LASTEXITCODE : restauration incomplete."; exit 1 }
} finally {
  Remove-Item $travail -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Verification -------------------------------------------------------------
$apres = Executer "select coalesce((select count(*)::text from `"EmailAccount`"),'0')||' compte(s), '||coalesce((select count(*)::text from `"Rule`"),'0')||' regle(s), '||coalesce((select count(*)::text from `"DigestItem`"),'0')||' element(s) de recap';"
Ok "Base restauree : $($apres -join '')"
exit 0
