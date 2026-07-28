@echo off
rem ============================================================
rem   Gestion Mails - construire le fichier .env
rem   (premiere installation d'une nouvelle organisation)
rem   Double-cliquer ce fichier. Un assistant pose les questions.
rem ============================================================
setlocal

set "PS1=%~dp0configurer-services.ps1"
if not exist "%PS1%" set "PS1=%~dp0.claude\configurer-services.ps1"

if not exist "%PS1%" (
  echo.
  echo ERREUR : configurer-services.ps1 est introuvable a cote de ce fichier.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"
echo.
pause
exit /b %RC%
