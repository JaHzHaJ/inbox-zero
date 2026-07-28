@echo off
rem ============================================================
rem   Gestion Mails - changer de mode
rem   local   : base et Redis dans Docker, sur ce poste
rem   partage : base et Redis heberges, communs a plusieurs postes
rem ============================================================
setlocal

set "PS1=%~dp0basculer-mode.ps1"
if not exist "%PS1%" set "PS1=%~dp0.claude\basculer-mode.ps1"

if not exist "%PS1%" (
  echo.
  echo ERREUR : basculer-mode.ps1 est introuvable a cote de ce fichier.
  echo.
  pause
  exit /b 1
)

set "ARGS="
if exist "%~dp0apps\web\.env" set "ARGS=-RepoPath "%~dp0.""

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
echo.
pause
endlocal
