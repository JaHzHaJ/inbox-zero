@echo off
rem ============================================================
rem   Gestion Mails - remise en service
rem   A lancer au retour de conges, ou quand plus rien ne marche.
rem   Double-cliquer ce fichier : un diagnostic s'affiche d'abord.
rem ============================================================
setlocal

rem Le script est cherche a cote de ce fichier (kit decompresse, tout a plat),
rem puis dans .claude\ (copie du depot).
set "PS1=%~dp0remise-en-service.ps1"
if not exist "%PS1%" set "PS1=%~dp0.claude\remise-en-service.ps1"

if not exist "%PS1%" (
  echo.
  echo ERREUR : remise-en-service.ps1 est introuvable a cote de ce fichier.
  echo.
  pause
  exit /b 1
)

rem Depuis le kit, le depot n'est pas ici : install.ps1 le pose par defaut dans
rem %USERPROFILE%\dev\inbox-zero. On ne passe -RepoPath que si ce fichier est
rem bien a la racine du depot.
set "ARGS="
if exist "%~dp0apps\web\.env" set "ARGS=-RepoPath "%~dp0.""

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%
echo.
pause
endlocal
