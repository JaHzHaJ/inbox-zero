@echo off
rem Ouvre le dossier des journaux de Gestion Mails dans l'Explorateur.
rem Utile quand le recap n'est pas arrive : tout y est trace.
set "LOGDIR=%LOCALAPPDATA%\GestionMails\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
start "" "%LOGDIR%"
