@echo off
rem Arrete le serveur de l'application (port 3000), sans toucher au reste.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0arreter-serveur.ps1" %*
exit /b %errorlevel%
