@echo off
rem ============================================================
rem   Gestion Mails - desactiver ou desinstaller
rem   Double-cliquer ce fichier. Un menu s'affiche.
rem ============================================================
setlocal

set "PS1=%~dp0uninstall.ps1"
if not exist "%PS1%" set "PS1=%~dp0.claude\uninstall.ps1"

if not exist "%PS1%" (
  echo.
  echo ERREUR : uninstall.ps1 est introuvable a cote de ce fichier.
  echo.
  pause
  exit /b 1
)

echo.
echo   1 = Desactiver seulement  ^(rien n'est supprime, reversible^)
echo   2 = Desinstaller l'application  ^(tache, raccourci, conteneurs, depot^)
echo   3 = Desinstaller + Docker, Node et pnpm  ^(attention : partages^)
echo   0 = Annuler
echo.
set "CHOIX="
set /p "CHOIX=Votre choix : "

if "%CHOIX%"=="1" set "ARGS="
if "%CHOIX%"=="2" set "ARGS=-Desinstaller"
if "%CHOIX%"=="3" set "ARGS=-Desinstaller -AvecDocker -AvecNode -AvecPnpm"
if "%CHOIX%"=="0" goto :fin
if not defined ARGS if not "%CHOIX%"=="1" (
  echo Choix non reconnu, rien n'a ete fait.
  goto :fin
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %ARGS%

:fin
echo.
pause
endlocal
