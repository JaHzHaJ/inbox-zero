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
#>
[CmdletBinding()]
param(
  [string] $Destination,
  [string] $RepoPath,
  [switch] $SansSecrets
)

$ErrorActionPreference = 'Stop'

# Sous Windows PowerShell 5.1, $PSScriptRoot est vide pendant l'evaluation des
# valeurs par defaut des parametres : on ne peut le lire qu'ici, dans le corps.
if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }

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

  $lisezMoi = @"
GESTION MAILS - installation sur un nouveau poste
=================================================

1. Decompresser ce dossier n'importe ou (le Bureau convient tres bien).
2. Double-cliquer installer.cmd.
3. Suivre les eventuelles demandes de confirmation.

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

  [System.IO.File]::WriteAllText(
    (Join-Path $atelier 'LISEZ-MOI.txt'),
    $lisezMoi,
    (New-Object System.Text.UTF8Encoding($false))
  )

  $zip = Join-Path $Destination 'Gestion-Mails-Installation.zip'
  if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
  Compress-Archive -Path (Join-Path $atelier '*') -DestinationPath $zip -CompressionLevel Optimal

  $taille = [math]::Round((Get-Item $zip).Length / 1KB, 1)
  Write-Host "Kit cree : $zip  ($taille Ko)" -ForegroundColor Green
  Write-Host ""
  Get-ChildItem $atelier | ForEach-Object {
    "  {0,-20} {1,8} o" -f $_.Name, $_.Length
  }
  if (-not $SansSecrets) {
    Write-Host ""
    Write-Host "Ce kit contient le .env : ne pas le diffuser hors de tes postes." -ForegroundColor Yellow
  }
} finally {
  Remove-Item -LiteralPath $atelier -Recurse -Force -ErrorAction SilentlyContinue
}
