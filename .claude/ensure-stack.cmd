@echo off
rem Monte la pile Gestion Mails et sort 0 si tout repond.
rem Appele par digest-cron.cmd et ouvrir-gestion-mails.cmd.
rem Argument 1 optionnel : fichier journal.
rem
rem Deux modes, DEDUITS du .env (aucun fichier d'etat a synchroniser, donc
rem aucun reglage qui puisse mentir sur la realite) :
rem   - LOCAL   : base et Redis dans Docker -> moteur + conteneurs + serveur
rem   - PARTAGE : base Supabase et Redis Upstash -> serveur seulement
rem En mode partage on economise jusqu'a 6 minutes de demarrage a froid, et le
rem poste n'a plus besoin de Docker du tout.
setlocal
rem Racine deduite du script : aucun chemin en dur, portable d'un poste a l'autre.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

rem Journaux dans le profil utilisateur (hors OneDrive, hors depot public).
set "LOGDIR=%LOCALAPPDATA%\GestionMails\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

set "LOG=%~1"
if not defined LOG set "LOG=%LOGDIR%\ensure-stack.log"
for %%F in ("%LOG%") do if %%~zF GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul 2>&1

rem --- 0. Mode ---
rem findstr sur le fichier plutot qu'une variable : l'URL contient un "&", que
rem cmd interpreterait comme un separateur de commandes. L'ancrage "^" est
rem indispensable : il ignore la ligne "# MODE-LOCAL DATABASE_URL=...localhost"
rem laissee en commentaire pour permettre le retour arriere.
set "MODE=partage"
findstr /i /r /c:"^DATABASE_URL=.*localhost" /c:"^DATABASE_URL=.*127\.0\.0\.1" "%ROOT%\apps\web\.env" >nul 2>&1
if not errorlevel 1 set "MODE=local"
echo [%date% %time%] mode %MODE% >> "%LOG%"
if /i "%MODE%"=="partage" goto :serveur

rem --- 1. Moteur Docker (mode local uniquement) ---
docker info >nul 2>&1
if not errorlevel 1 goto :docker_ok

rem Docker Desktop 4.8x s'installe PAR UTILISATEUR (%LOCALAPPDATA%), plus sous
rem %ProgramFiles%. Un "start" sur un chemin inexistant ouvre une boite de
rem dialogue Windows : on teste l'existence avant de lancer.
set "DOCKER_EXE="
if exist "%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe" set "DOCKER_EXE=%LOCALAPPDATA%\Programs\DockerDesktop\Docker Desktop.exe"
if not defined DOCKER_EXE if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" set "DOCKER_EXE=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not defined DOCKER_EXE if exist "%ProgramW6432%\Docker\Docker\Docker Desktop.exe" set "DOCKER_EXE=%ProgramW6432%\Docker\Docker\Docker Desktop.exe"
if not defined DOCKER_EXE call :from_registry HKCU
if not defined DOCKER_EXE call :from_registry HKLM

if not defined DOCKER_EXE (
  echo [%date% %time%] ERREUR: Docker Desktop introuvable ^(cherche dans LOCALAPPDATA\Programs\DockerDesktop, ProgramFiles\Docker\Docker et le registre^) >> "%LOG%"
  exit /b 2
)

echo [%date% %time%] Docker absent, lancement de "%DOCKER_EXE%" >> "%LOG%"
start "" "%DOCKER_EXE%"
rem Demarrage a froid (WSL2 + moteur) : jusqu'a 6 minutes.
for /l %%i in (1,1,72) do (
  rem ping plutot que timeout : timeout.exe echoue des que l'entree standard
  rem est redirigee ("la redirection de l'entree n'est pas prise en charge"),
  rem ce qui vide la boucle d'attente de sa substance. ping est insensible.
  ping -n 6 127.0.0.1 >nul
  docker info >nul 2>&1
  if not errorlevel 1 goto :docker_ok
)
echo [%date% %time%] ERREUR: moteur Docker toujours indisponible apres 6 min >> "%LOG%"
exit /b 1

:from_registry
for /f "usebackq tokens=2,*" %%a in (`reg query "%~1\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop" /v InstallLocation 2^>nul`) do (
  if exist "%%~b\Docker Desktop.exe" set "DOCKER_EXE=%%~b\Docker Desktop.exe"
)
goto :eof

:docker_ok

rem --- 2. Conteneurs (mode local ; idempotent : remonte Postgres/Redis arretes) ---
docker compose -f "%ROOT%\docker-compose.dev.yml" up -d >> "%LOG%" 2>&1
if errorlevel 1 (
  echo [%date% %time%] ERREUR: docker compose up a echoue >> "%LOG%"
  exit /b 3
)

:serveur
rem --- 3. Serveur Next (les deux modes) ---
rem Delai genereux : un serveur deja lance mais en train de recompiler met
rem plusieurs secondes a repondre. Trop court, on en demarre un second pour rien.
curl -s -o nul -m 20 http://localhost:3000/login
if not errorlevel 1 exit /b 0
echo [%date% %time%] serveur absent, demarrage... >> "%LOG%"
rem Lance sans fenetre et sans attendre : le serveur tourne en continu et doit
rem survivre a la fin de ce script, du Planificateur ou du shell appelant.
rem La sortie du serveur part dans %LOGDIR%\serveur.log (voir dev-web.cmd).
wscript.exe //B //Nologo "%ROOT%\.claude\run-hidden.vbs" 0 "%ROOT%\.claude\dev-web.cmd"
for /l %%i in (1,1,72) do (
  rem ping plutot que timeout : timeout.exe echoue des que l'entree standard
  rem est redirigee ("la redirection de l'entree n'est pas prise en charge"),
  rem ce qui vide la boucle d'attente de sa substance. ping est insensible.
  ping -n 6 127.0.0.1 >nul
  curl -s -o nul -m 5 http://localhost:3000/login
  if not errorlevel 1 exit /b 0
)
echo [%date% %time%] ERREUR: serveur indisponible apres attente >> "%LOG%"
exit /b 1
