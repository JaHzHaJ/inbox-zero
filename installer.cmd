@echo off
rem ============================================================
rem   Gestion Mails - installation sur un nouveau poste Windows
rem   Double-cliquer ce fichier. Rien d'autre a faire.
rem ============================================================
setlocal

rem Le script PowerShell est cherche a cote de ce fichier (copie OneDrive),
rem puis dans .claude\ (copie du depot).
set "PS1=%~dp0install.ps1"
if not exist "%PS1%" set "PS1=%~dp0.claude\install.ps1"

if not exist "%PS1%" (
  echo.
  echo ERREUR : install.ps1 est introuvable a cote de ce fichier.
  echo Copier install.ps1 et installer.cmd dans le meme dossier.
  echo.
  pause
  exit /b 1
)

echo Installation de Gestion Mails...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

echo.
if not "%RC%"=="0" (
  echo L'installation s'est arretee sur une erreur ^(code %RC%^).
) else (
  echo Installation terminee.
)
echo.
pause
exit /b %RC%
