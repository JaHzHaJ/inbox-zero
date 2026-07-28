<#
.SYNOPSIS
  Arrete le serveur de l'application qui ecoute sur le port 3000.

.DESCRIPTION
  Trois pieges, tous rencontres en conditions reelles, expliquent la prudence
  de ce script :

  1. Tuer le processus qui ecoute ne suffit pas : le superviseur de Next
     relance aussitot son worker. Il faut remonter jusqu'au cmd racine.
  2. On ne remonte qu'a travers des node.exe. Au-dela se trouvent le terminal
     ou l'Explorateur : les tuer emporterait des programmes sans rapport.
  3. Si le port 3000 est occupe par un tout autre programme, on n'y touche pas.

.EXAMPLE
  .\arreter-serveur.ps1
  .\arreter-serveur.ps1 -Silencieux
#>
[CmdletBinding()]
param(
  [int] $Port = 3000,
  [switch] $Silencieux
)

$ErrorActionPreference = 'Stop'
function Dire($t, $couleur = 'DarkGray') { if (-not $Silencieux) { Write-Host "    $t" -ForegroundColor $couleur } }

$connexion = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
  Select-Object -First 1
if (-not $connexion) {
  Dire "Aucun serveur n'ecoute sur le port $Port."
  exit 0
}

$proprietaire = Get-CimInstance Win32_Process -Filter "ProcessId=$($connexion.OwningProcess)" -ErrorAction SilentlyContinue
if (-not $proprietaire) {
  Dire "Le processus du port $Port a deja disparu."
  exit 0
}

if ($proprietaire.Name -ne 'node.exe') {
  Dire "Le port $Port est occupe par $($proprietaire.Name), pas par l'application : rien n'est arrete." 'Yellow'
  exit 0
}

$racine = $proprietaire.ProcessId
$courant = $proprietaire.ParentProcessId
for ($i = 0; $i -lt 6; $i++) {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$courant" -ErrorAction SilentlyContinue
  if (-not $p) { break }
  if ($p.Name -eq 'cmd.exe') { $racine = $p.ProcessId; break }
  if ($p.Name -ne 'node.exe') { break }
  $racine = $p.ProcessId
  $courant = $p.ParentProcessId
}

function Stop-Arbre($id) {
  Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Arbre $_.ProcessId }
  Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
}
Stop-Arbre $racine
Start-Sleep -Seconds 2

$reste = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($reste) {
  Dire "Le port $Port repond encore : l'arret a echoue." 'Red'
  exit 1
}
Dire 'Serveur arrete.' 'Green'
exit 0
