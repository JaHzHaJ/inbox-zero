@echo off
rem Lance le serveur Inbox Zero avec Node 24 (fnm) si disponible.
rem Racine deduite du script : portable d'un poste a l'autre.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

set "FNM_NODE=%APPDATA%\fnm\node-versions\v24.18.0\installation"
if exist "%FNM_NODE%\node.exe" set "PATH=%FNM_NODE%;%PATH%"

cd /d "%ROOT%\apps\web"
set NODE_OPTIONS=--max_old_space_size=6144
call node_modules\.bin\next.CMD dev --turbopack
