@echo off
rem Lance le serveur Inbox Zero avec Node 24 (fnm) si disponible.
rem Racine deduite du script : portable d'un poste a l'autre.
rem Toute la sortie part dans un fichier : lance en mode cache, il n'y a plus
rem de console pour l'afficher.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

set "LOGDIR=%LOCALAPPDATA%\GestionMails\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
set "LOG=%LOGDIR%\serveur.log"

rem Rotation par taille : la sortie de Next en mode developpement est tres
rem bavarde. Au-dela de 5 Mo on archive et on repart a zero (2 fichiers max).
for %%F in ("%LOG%") do if %%~zF GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul 2>&1

set "FNM_NODE=%APPDATA%\fnm\node-versions\v24.18.0\installation"
if exist "%FNM_NODE%\node.exe" set "PATH=%FNM_NODE%;%PATH%"

cd /d "%ROOT%\apps\web"
set NODE_OPTIONS=--max_old_space_size=6144

echo. >> "%LOG%"
echo [%date% %time%] === demarrage du serveur === >> "%LOG%"
call node_modules\.bin\next.CMD dev --turbopack >> "%LOG%" 2>&1
