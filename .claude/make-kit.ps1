<#
.SYNOPSIS
  Fabrique le ZIP d'installation portable pour un autre poste.

.DESCRIPTION
  Assemble un kit d'amorcage autonome : les deux scripts, la documentation, et
  le .env. Le .env n'est ajoute qu'ici, au moment de la fabrication - il n'est
  jamais versionne, le depot etant public.

  Le ZIP se decompresse n'importe ou : install.ps1 cherche le .env a cote de
  lui en priorite.

.EXAMPLE
  .\make-kit.ps1
  .\make-kit.ps1 -Destination "$env:OneDriveCommercial\Gestion Mails"
  .\make-kit.ps1 -SansSecrets     # kit a partager, sans le .env
  .\make-kit.ps1 -Generique       # kit pour une NOUVELLE organisation
#>
[CmdletBinding()]
param(
  [string] $Destination,
  [string] $RepoPath,
  [switch] $SansSecrets,
  # Kit pour une autre organisation : aucun secret, assistant de premiere
  # configuration et guide dedie embarques, nom de ZIP distinct.
  [switch] $Generique
)

$ErrorActionPreference = 'Stop'

# Sous Windows PowerShell 5.1, $PSScriptRoot est vide pendant l'evaluation des
# valeurs par defaut des parametres : on ne peut le lire qu'ici, dans le corps.
if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }

# Un kit generique n'embarque JAMAIS de secrets, quoi qu'il arrive.
if ($Generique) { $SansSecrets = $true }

if (-not $Destination) {
  $base = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } else { $env:OneDrive }
  $Destination = Join-Path $base 'Gestion Mails'
}
if (-not (Test-Path $Destination)) {
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$atelier = Join-Path $env:TEMP "gestion-mails-kit-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $atelier | Out-Null

try {
  # Le kit doit embarquer TOUT ce que install.ps1 appelle : un script manquant
  # ne se decouvrirait que sur le poste neuf, au milieu de l'installation.
  $aCopier = @(
    @{ source = Join-Path $RepoPath 'installer.cmd';                 nom = 'installer.cmd';           requis = $true }
    @{ source = Join-Path $RepoPath 'desinstaller.cmd';              nom = 'desinstaller.cmd';        requis = $true }
    @{ source = Join-Path $RepoPath 'remise-en-service.cmd';         nom = 'remise-en-service.cmd';   requis = $true }
    @{ source = Join-Path $RepoPath 'basculer-mode.cmd';             nom = 'basculer-mode.cmd';       requis = $true }
    @{ source = Join-Path $RepoPath '.claude\install.ps1';           nom = 'install.ps1';             requis = $true }
    @{ source = Join-Path $RepoPath '.claude\uninstall.ps1';         nom = 'uninstall.ps1';           requis = $true }
    @{ source = Join-Path $RepoPath '.claude\configurer-ia.ps1';     nom = 'configurer-ia.ps1';       requis = $true }
    @{ source = Join-Path $RepoPath '.claude\remise-en-service.ps1'; nom = 'remise-en-service.ps1';   requis = $true }
    @{ source = Join-Path $RepoPath '.claude\basculer-mode.ps1';     nom = 'basculer-mode.ps1';       requis = $true }
    @{ source = Join-Path $RepoPath '.claude\restaurer-base.ps1';    nom = 'restaurer-base.ps1';      requis = $true }
    @{ source = Join-Path $RepoPath '.claude\sauvegarder-base.ps1';  nom = 'sauvegarder-base.ps1';    requis = $true }
    @{ source = Join-Path $RepoPath '.claude\arreter-serveur.ps1';   nom = 'arreter-serveur.ps1';     requis = $true }
    @{ source = Join-Path $RepoPath 'INSTALLATION.md';               nom = 'INSTALLATION.md';         requis = $true }
  )

  if ($Generique) {
    $aCopier += @(
      @{ source = Join-Path $RepoPath 'configurer-services.cmd';               nom = 'configurer-services.cmd';               requis = $true }
      @{ source = Join-Path $RepoPath '.claude\configurer-services.ps1';       nom = 'configurer-services.ps1';               requis = $true }
      @{ source = Join-Path $RepoPath '.claude\modele.env';                    nom = 'modele.env';                            requis = $true }
      @{ source = Join-Path $RepoPath 'INSTALLATION-NOUVELLE-ORGANISATION.md'; nom = 'INSTALLATION-NOUVELLE-ORGANISATION.md'; requis = $true }
    )
  }

  foreach ($f in $aCopier) {
    if (-not (Test-Path $f.source)) {
      if ($f.requis) { throw "Fichier manquant : $($f.source)" }
      continue
    }
    Copy-Item $f.source (Join-Path $atelier $f.nom) -Force
  }

  if (-not $SansSecrets) {
    $env_source = Join-Path $RepoPath 'apps\web\.env'
    if (-not (Test-Path $env_source)) {
      throw "Fichier .env introuvable : $env_source (utiliser -SansSecrets pour un kit sans secrets)"
    }
    Copy-Item $env_source (Join-Path $atelier '.env') -Force
  }

  $lisezMoi = if ($Generique) { @"
GESTION MAILS - kit pour une NOUVELLE organisation
==================================================

Ce kit ne contient AUCUN secret : la configuration se construit chez vous.

1. Decompresser ce dossier n'importe ou (le Bureau convient tres bien).
2. Double-cliquer installer.cmd.
3. A la question du MODE, appuyer sur Entree (mode local) -- ou choisir
   " partage " si plusieurs postes doivent suivre la meme boite.
4. Faute de fichier .env, l'installeur propose de lancer L'ASSISTANT DE
   CONFIGURATION : il guide la creation des comptes de service (application
   Azure AD, Resend, et Supabase/Upstash en mode partage), verifie chaque
   saisie et genere les secrets internes.
   L'assistant peut aussi etre lance seul, avant : configurer-services.cmd.

Le detail de chaque etape (adresses a saisir dans Azure, permissions
exactes) : INSTALLATION-NOUVELLE-ORGANISATION.md, dans ce dossier.

L'application s'installe par defaut dans %USERPROFILE%\dev\inbox-zero :
  - JAMAIS dans OneDrive (la synchronisation casse l'installation)
  - un chemin court, sans caracteres exotiques

LICENCE : AGPL + clauses Inbox Zero. Usage exempte jusqu'a 5 utilisateurs
en entreprise ; pas de monetisation du logiciel. Details dans le guide.

Le fichier .env PRODUIT par l'assistant contient des secrets :
ne pas le diffuser hors des postes de votre organisation.
"@
  } else { @"
GESTION MAILS - installation sur un nouveau poste
=================================================

1. Decompresser ce dossier n'importe ou (le Bureau convient tres bien).
2. Double-cliquer installer.cmd.
3. Repondre aux deux questions :
     - le MODE : " Partage avec un autre poste " est le bon choix pour un
       poste qui rejoint la boite commune (c'est le defaut) ;
     - le FOURNISSEUR D'IA : CLI Claude par defaut.
4. Suivre les eventuelles demandes de confirmation.

L'emplacement du dossier decompresse n'a aucune importance.

En revanche, l'application elle-meme s'installe par defaut dans
%USERPROFILE%\dev\inbox-zero. Trois regles pour cet emplacement :
  - JAMAIS dans OneDrive (la synchronisation casse l'installation)
  - un chemin court (limite de longueur de Windows)
  - pas de caracteres exotiques

Pour changer d'emplacement :
  powershell -ExecutionPolicy Bypass -File install.ps1 -RepoPath D:\dev\inbox-zero

Pour tout desactiver ou desinstaller : double-cliquer desinstaller.cmd.

$(if ($SansSecrets) {
"ATTENTION : ce kit ne contient PAS le fichier .env (secrets).
Il faut le placer a cote de installer.cmd avant de lancer l'installation."
} else {
"Le fichier .env de ce dossier contient des secrets (cles Azure, Resend,
cles de chiffrement). Ne pas le diffuser."
})

Details complets dans INSTALLATION.md.
"@
  }

  [System.IO.File]::WriteAllText(
    (Join-Path $atelier 'LISEZ-MOI.txt'),
    $lisezMoi,
    (New-Object System.Text.UTF8Encoding($false))
  )

  # Un nom de ZIP PAR VARIANTE : sous un nom unique, un kit sans secrets
  # ecraserait le kit complet -- et surtout l'inverse, un ZIP a secrets
  # prendrait la place d'un fichier que l'on croit diffusable.
  $nomZip = if ($Generique) { 'Gestion-Mails-Kit-Generique.zip' }
  elseif ($SansSecrets) { 'Gestion-Mails-Installation-sans-secrets.zip' }
  else { 'Gestion-Mails-Installation.zip' }
  $zip = Join-Path $Destination $nomZip
  if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $atelier '*') -DestinationPath $zip -CompressionLevel Optimal

  $taille = [math]::Round((Get-Item $zip).Length / 1KB, 1)
  Write-Host "Kit cree : $zip  ($taille Ko)" -ForegroundColor Green
  Write-Host ""
  Get-ChildItem $atelier | ForEach-Object {
    "  {0,-20} {1,8} o" -f $_.Name, $_.Length
  }

  # --- Entretien du dossier de destination -------------------------------------
  # Le ZIP est le SEUL chemin d'installation. Des copies de scripts posees a
  # plat dans le dossier OneDrive ont deja derive une fois (audit du
  # 28/07/2026) : on les supprime, et on n'entretient a cote du ZIP que le
  # .env de reference, sa variante locale et la documentation.
  # Un kit GENERIQUE se fabrique vers un dossier quelconque, destine a etre
  # transmis : on n'y touche a rien d'autre que le ZIP.
  if ($Generique) {
    Write-Host ""
    Write-Host "Kit generique pret a transmettre : aucun secret embarque." -ForegroundColor Green
    return
  }
  foreach ($vieux in @('installer.cmd', 'desinstaller.cmd', 'install.ps1', 'uninstall.ps1')) {
    $chemin = Join-Path $Destination $vieux
    if (Test-Path $chemin) {
      Remove-Item -LiteralPath $chemin -Force
      Write-Host "Copie a plat supprimee (le ZIP fait foi) : $vieux" -ForegroundColor DarkGray
    }
  }
  Copy-Item (Join-Path $RepoPath 'INSTALLATION.md') (Join-Path $Destination 'INSTALLATION.md') -Force

  if (-not $SansSecrets) {
    Copy-Item $env_source (Join-Path $Destination '.env') -Force
    $lignes = @(Get-Content $env_source)
    if (($lignes | Where-Object { $_ -match '^DATABASE_URL=.*(localhost|127\.0\.0\.1)' })) {
      Write-Host "ATTENTION : le .env embarque est en mode LOCAL (base sur ce poste)." -ForegroundColor Yellow
    }
    # Variante locale prete a l'emploi : les lignes en reserve # MODE-LOCAL
    # deviennent actives, l'actif du jour part en reserve. C'est le fichier
    # que les messages d'install.ps1 et basculer-mode.ps1 invitent a prendre.
    $variables = @('DATABASE_URL', 'DIRECT_URL', 'UPSTASH_REDIS_URL', 'UPSTASH_REDIS_TOKEN')
    if (@($lignes | Where-Object { $_ -like '# MODE-LOCAL *' }).Count -gt 0) {
      $locale = foreach ($l in $lignes) {
        if ($l -like '# MODE-LOCAL *') { $l.Substring('# MODE-LOCAL '.Length) }
        elseif ($l -match '^\s*([A-Z0-9_]+)\s*=' -and $variables -contains $Matches[1]) { "# MODE-PARTAGE $l" }
        else { $l }
      }
      [System.IO.File]::WriteAllLines(
        (Join-Path $Destination '.env.local-docker'),
        [string[]] $locale,
        (New-Object System.Text.UTF8Encoding($false))
      )
      Write-Host "Compagnons OneDrive rafraichis : .env, .env.local-docker, INSTALLATION.md" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Ce kit contient le .env : ne pas le diffuser hors de tes postes." -ForegroundColor Yellow
  }
} finally {
  Remove-Item -LiteralPath $atelier -Recurse -Force -ErrorAction SilentlyContinue
}
