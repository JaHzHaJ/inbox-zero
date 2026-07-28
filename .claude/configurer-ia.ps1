<#
.SYNOPSIS
  Choisit et verifie le fournisseur d'intelligence artificielle de ce poste.

.DESCRIPTION
  Le classement des mails et les resumes du recap passent par une IA. Deux
  façons de la fournir :

    claude-cli - le programme en ligne de commande Claude, deja inclus dans les
                 dependances. Il utilise l'abonnement : aucun cout au message.
                 ATTENTION : la SESSION est propre a chaque machine. Sur un
                 poste neuf, il faut s'y connecter une fois.
    cle-api    - une cle API Anthropic. Facturee a l'usage.

  Le choix est ecrit dans apps\web\.env.local, qui n'appartient qu'a CE poste :
  le fichier .env, lui, reste identique partout. C'est ce qui permet a un poste
  d'utiliser l'abonnement et a l'autre une cle API sans que les deux fichiers
  divergent.

.EXAMPLE
  .\configurer-ia.ps1
  .\configurer-ia.ps1 -Choix claude-cli
  .\configurer-ia.ps1 -Choix cle-api -SansTest
#>
[CmdletBinding()]
param(
  [ValidateSet('claude-cli', 'cle-api', 'plus-tard')]
  [string] $Choix,
  [string] $RepoPath,
  [switch] $SansTest
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot est VIDE pendant l'evaluation des valeurs par defaut des
# parametres sous PowerShell 5.1 : ce calcul doit rester dans le corps.
if (-not $RepoPath) { $RepoPath = Split-Path $PSScriptRoot -Parent }
$web = Join-Path $RepoPath 'apps\web'
$envLocal = Join-Path $web '.env.local'

# Modele par defaut du fournisseur anthropic dans ce depot
# (apps\web\utils\llms\model.ts).
$ModeleAnthropic = 'claude-sonnet-4-6'

function Info($t) { Write-Host "    $t" -ForegroundColor DarkGray }
function Ok($t) { Write-Host "    [OK] $t" -ForegroundColor Green }
function Avert($t) { Write-Host "    [!] $t" -ForegroundColor Yellow }

function DefinirCle($chemin, $cle, $valeur) {
  # Remplace la ligne si elle existe, l'ajoute sinon. Le fichier peut ne pas
  # exister : c'est le cas normal au premier passage.
  $lignes = if (Test-Path $chemin) { @(Get-Content $chemin) } else { @() }
  $trouve = $false
  $sortie = foreach ($l in $lignes) {
    if ($l -match "^\s*$([regex]::Escape($cle))=") { $trouve = $true; "$cle=$valeur" }
    else { $l }
  }
  if (-not $trouve) { $sortie = @($sortie) + "$cle=$valeur" }
  # UTF8 sans BOM : ce fichier est lu par Node, pas par PowerShell.
  [System.IO.File]::WriteAllLines($chemin, [string[]] $sortie, (New-Object System.Text.UTF8Encoding $false))
}

function TesterIa {
  # Un vrai appel, pas une simple presence de fichier : c'est la seule facon de
  # savoir si la session Claude existe sur CE poste.
  $smoke = Join-Path $web 'smoke-claude-code.mjs'
  if (-not (Test-Path $smoke)) {
    Avert "Script de test introuvable ($smoke) : verification sautee."
    return $true
  }
  Info 'Appel de test en cours (jusqu a 2 minutes)...'
  Push-Location $web
  try {
    $sortie = & node 'smoke-claude-code.mjs' 'haiku' 2>&1 | Out-String
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally { Pop-Location }
}

if (-not $Choix) {
  Write-Host ""
  Write-Host "Comment l'IA est-elle fournie sur ce poste ?" -ForegroundColor White
  Write-Host "  1. Programme Claude en ligne de commande (defaut)" -ForegroundColor White
  Write-Host "     Utilise l'abonnement : aucun cout au message. Demande d'etre" -ForegroundColor DarkGray
  Write-Host "     connecte une fois sur ce poste." -ForegroundColor DarkGray
  Write-Host "  2. Cle API Anthropic" -ForegroundColor White
  Write-Host "     Facturee a l'usage. La cle est demandee maintenant, masquee." -ForegroundColor DarkGray
  Write-Host "  3. Plus tard" -ForegroundColor White
  Write-Host "     Rien n'est ecrit. Le classement et les resumes resteront" -ForegroundColor DarkGray
  Write-Host "     inactifs jusqu'a ce que ce script soit relance." -ForegroundColor DarkGray
  $r = Read-Host "Votre choix [1-3]"
  $Choix = switch ($r) { '2' { 'cle-api' } '3' { 'plus-tard' } default { 'claude-cli' } }
}

switch ($Choix) {

  'plus-tard' {
    Avert 'Aucun fournisseur configure.'
    Info 'Le rattrapage et le recap fonctionneront, mais les mails ne seront ni'
    Info 'classes ni resumes tant que ce choix n a pas ete fait.'
    Info "Pour y revenir : .claude\configurer-ia.cmd"
    exit 0
  }

  'cle-api' {
    $secure = Read-Host 'Cle API Anthropic (la saisie reste invisible)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $cle = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    if (-not $cle) { Avert 'Aucune cle saisie, rien de modifie.'; exit 1 }

    DefinirCle $envLocal 'CLI_LLM_ENABLED' 'false'
    DefinirCle $envLocal 'DEFAULT_LLMS' "anthropic:$ModeleAnthropic"
    DefinirCle $envLocal 'ECONOMY_LLMS' "anthropic:$ModeleAnthropic"
    DefinirCle $envLocal 'LLM_API_KEY' $cle
    Ok "Cle enregistree dans $envLocal (ce fichier ne quitte jamais ce poste)"
  }

  'claude-cli' {
    DefinirCle $envLocal 'CLI_LLM_ENABLED' 'true'
    # Liste ordonnee : le premier fournisseur valide gagne, les suivants servent
    # de repli. Si une cle API est ajoutee plus tard, il suffira de l'ajouter
    # ici pour que le poste bascule dessus quand la session Claude manque.
    DefinirCle $envLocal 'DEFAULT_LLMS' 'claude-code:sonnet'
    DefinirCle $envLocal 'ECONOMY_LLMS' 'claude-code:haiku'
    Ok "Fournisseur en ligne de commande enregistre dans $envLocal"

    if (-not $SansTest) {
      if (TesterIa) {
        Ok 'Le programme Claude repond : ce poste est pret.'
      } else {
        Write-Host ""
        Avert "Le programme Claude ne repond pas."
        Info 'Cause la plus frequente sur un poste neuf : personne ne s y est'
        Info 'encore connecte. La session ne se copie pas d une machine a l autre.'
        Write-Host ""
        Info 'A faire, dans une AUTRE fenetre :'
        Info '  1. ouvrir un terminal'
        Info '  2. taper : claude'
        Info "  3. se connecter avec le compte de l'abonnement"
        Write-Host ""
        $r = Read-Host 'Une fois connecte, appuyer sur Entree pour reessayer (ou T pour terminer)'
        if ($r -notmatch '^(t|T)') {
          if (TesterIa) {
            Ok 'Le programme Claude repond : ce poste est pret.'
          } else {
            Avert 'Toujours pas de reponse. Le reglage est enregistre malgre tout.'
            Info "Relancer .claude\configurer-ia.cmd apres avoir resolu la connexion."
            exit 1
          }
        }
      }
    }
  }
}

exit 0
