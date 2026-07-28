<#
.SYNOPSIS
  Fait passer ce poste du mode local au mode partage, ou l'inverse.

.DESCRIPTION
  Un seul fichier .env porte les deux configurations. Les lignes du mode
  inactif y restent, prefixees par un marqueur :

      DATABASE_URL="...supabase..."                   <- active
      # MODE-LOCAL DATABASE_URL="...localhost..."     <- en reserve

  Basculer revient a echanger les marqueurs. Un seul fichier de secrets, donc
  aucun risque que les valeurs communes (Azure, Resend, cles de chiffrement)
  divergent entre deux copies.

  ATTENTION, dans le sens partage -> local : les deux bases se mettent alors a
  vivre chacune de leur cote. Il n'existe aucune fusion possible ensuite.

.EXAMPLE
  .\basculer-mode.ps1              # bascule vers l'autre mode, en demandant
  .\basculer-mode.ps1 -Vers local
  .\basculer-mode.ps1 -Vers partage -SansConfirmation
#>
[CmdletBinding()]
param(
  [ValidateSet('local', 'partage')]
  [string] $Vers,
  [string] $RepoPath,
  [switch] $SansConfirmation
)

$ErrorActionPreference = 'Stop'

if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$web = Join-Path $RepoPath 'apps\web'
$fichierEnv = Join-Path $web '.env'

# Les seules variables qui different d'un mode a l'autre.
$Variables = @('DATABASE_URL', 'DIRECT_URL', 'UPSTASH_REDIS_URL', 'UPSTASH_REDIS_TOKEN')

# Ce script vit dans .claude\ du depot ET a plat dans le kit decompresse :
# ses voisins se cherchent dans les deux dispositions.
function Voisin($nom) {
  $aCote = Join-Path $PSScriptRoot $nom
  if (Test-Path $aCote) { return $aCote }
  $dansDepot = Join-Path $RepoPath ".claude\$nom"
  if (Test-Path $dansDepot) { return $dansDepot }
  return $null
}

function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Avert($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }
function Stop2($t) { Write-Host "    [ECHEC] $t" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $fichierEnv)) { Stop2 "Fichier introuvable : $fichierEnv" }
$lignes = @(Get-Content $fichierEnv)

function ModeActuel($lignes) {
  foreach ($l in $lignes) {
    if ($l -match '^DATABASE_URL=') {
      return $(if ($l -match 'localhost|127\.0\.0\.1|@db:') { 'local' } else { 'partage' })
    }
  }
  return 'inconnu'
}

$actuel = ModeActuel $lignes
Write-Host ""
Write-Host "=== Bascule de mode ===" -ForegroundColor White
Info "Mode actuel : $actuel"

if (-not $Vers) { $Vers = if ($actuel -eq 'local') { 'partage' } else { 'local' } }
if ($Vers -eq $actuel) { Ok "Ce poste est deja en mode $Vers, rien a faire."; exit 0 }

# Verifier que les lignes du mode cible existent AVANT de toucher au fichier :
# une bascule a moitie faite laisserait le poste dans un etat batard.
$marqueurCible = "# MODE-$($Vers.ToUpper()) "
$disponibles = @($lignes | Where-Object { $_ -like "$marqueurCible*" })
if ($disponibles.Count -eq 0) {
  Stop2 @"
Le fichier .env ne contient aucune ligne en reserve pour le mode $Vers.
Il devrait comporter des lignes de la forme :
    $marqueurCible`DATABASE_URL="..."
Recuperer un .env complet dans le dossier OneDrive " Gestion Mails ",
ou en construire un : configurer-services.cmd (nouvelle organisation).
"@
}
Info "$($disponibles.Count) ligne(s) en reserve trouvee(s) pour le mode $Vers"

if ($Vers -eq 'local' -and -not $SansConfirmation) {
  Write-Host ""
  Avert 'Passage en mode LOCAL : ce poste va utiliser sa propre base, dans Docker.'
  Info 'A partir de cet instant, les mails traites ici ne seront plus visibles'
  Info "par l'autre poste, et inversement. Les deux bases divergent, et il"
  Info "n'existe aucun moyen de les refusionner ensuite."
  Write-Host ""
  $r = Read-Host 'Continuer ? (o/N)'
  if ($r -notmatch '^(o|O|oui|y|Y)$') { Write-Host '    Annule.'; exit 0 }
}

$marqueurRemise = "# MODE-$($actuel.ToUpper()) "
$sortie = foreach ($l in $lignes) {
  if ($l -like "$marqueurCible*") {
    # Activer la ligne en reserve
    $l.Substring($marqueurCible.Length)
  } elseif ($l -match '^\s*([A-Z0-9_]+)\s*=' -and $Variables -contains $Matches[1]) {
    # Mettre l'ancienne ligne active en reserve
    "$marqueurRemise$l"
  } else {
    $l
  }
}

Copy-Item $fichierEnv "$fichierEnv.avant-bascule" -Force
[System.IO.File]::WriteAllLines($fichierEnv, [string[]] $sortie, (New-Object System.Text.UTF8Encoding $false))

$verif = ModeActuel @(Get-Content $fichierEnv)
if ($verif -ne $Vers) {
  Copy-Item "$fichierEnv.avant-bascule" $fichierEnv -Force
  Stop2 "La bascule n'a pas pris ($verif au lieu de $Vers). Fichier restaure."
}
Ok "Fichier .env bascule en mode $Vers"

# En mode local, docker-compose lit le jeton SRH dans le .env RACINE du depot :
# on l'aligne sur la valeur qui vient d'etre activee, sinon le conteneur
# redis-http refuserait toutes les requetes de l'application.
if ($Vers -eq 'local') {
  $m = Select-String -Path $fichierEnv -Pattern '^UPSTASH_REDIS_TOKEN=(.+)$' | Select-Object -First 1
  if ($m) {
    $jetonSrh = $m.Matches[0].Groups[1].Value.Trim().Trim('"')
    [System.IO.File]::WriteAllLines((Join-Path $RepoPath '.env'), [string[]] @(
      '# Variables lues par docker-compose.dev.yml (compose lit le .env a la racine).',
      '# Doit rester aligne avec UPSTASH_REDIS_TOKEN de apps/web/.env.',
      "UPSTASH_REDIS_TOKEN=$jetonSrh"
    ), (New-Object System.Text.UTF8Encoding $false))
    Info 'Jeton SRH aligne dans le .env racine (docker-compose).'
  }
}

# Le serveur garde sa connexion a l'ancienne base en memoire : sans redemarrage
# la bascule n'a aucun effet visible.
Info 'Arret du serveur pour qu il reparte sur la nouvelle configuration...'
$as = Voisin 'arreter-serveur.ps1'; if ($as) { & $as -Silencieux }

Info 'Redemarrage de la pile...'
$es = Voisin 'ensure-stack.cmd'; if ($es) { & $es | Out-Null }

Push-Location $web
try {
  & node 'scripts\verifier-services.mjs'
  if ($LASTEXITCODE -ne 0) {
    Avert "Les services ne repondent pas encore en mode $Vers (details ci-dessus)."
    Info "Pour revenir en arriere : .\basculer-mode.ps1 -Vers $actuel"
    exit 1
  }
} finally { Pop-Location }

Ok "Ce poste fonctionne maintenant en mode $Vers."
exit 0
