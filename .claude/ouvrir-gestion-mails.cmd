@echo off
rem Ouvre le portail Gestion Mails apres avoir monte la pile si besoin
rem (Docker Desktop -> conteneurs -> serveur). Peut prendre 2-3 minutes
rem a froid ; instantane si tout tourne deja.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

echo Preparation de Gestion Mails (jusqu'a 3 minutes au premier lancement)...
call "%ROOT%\.claude\ensure-stack.cmd"
if errorlevel 1 (
  echo.
  echo Impossible de demarrer l'application. Consulter %ROOT%\.claude\ensure-stack.log
  pause
  exit /b 1
)

start "" "%ROOT%\.claude\portail-mails.html"
endlocal
