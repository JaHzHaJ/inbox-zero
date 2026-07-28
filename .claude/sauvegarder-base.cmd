@echo off
rem Sauvegarde la base de donnees dans %LOCALAPPDATA%\GestionMails\backups.
rem Les 8 dernieres sont conservees, chacune datee : aucune n'ecrase la precedente.
rem Argument /silencieux : sans affichage, pour la tache planifiee.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
rem Lancement manuel = sauvegarde tout de suite. Lancement par la tache
rem planifiee (/silencieux) = seulement si la derniere date de plus d'une
rem semaine.
set "OPT="
if /i "%~1"=="/silencieux" set "OPT=-Silencieux -SiNecessaire"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sauvegarder-base.ps1" -RepoPath "%ROOT%" %OPT%
exit /b %errorlevel%
