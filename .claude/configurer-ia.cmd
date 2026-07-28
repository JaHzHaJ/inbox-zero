@echo off
rem Choisit le fournisseur d'intelligence artificielle de ce poste.
rem A lancer a tout moment : a l'installation, ou plus tard pour renseigner une
rem cle API qui n'etait pas connue le jour de l'installation.
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0configurer-ia.ps1" -RepoPath "%ROOT%"
echo.
pause
endlocal
