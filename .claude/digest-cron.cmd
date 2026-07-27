@echo off
rem Rattrape les mails non traites puis declenche l'envoi du recap Inbox Zero.
rem Monte d'abord toute la pile (Docker -> conteneurs -> serveur) via ensure-stack.
rem Appele par la tache planifiee "InboxZero Recap 7h".
setlocal

rem Racine deduite du script : aucun chemin en dur, le depot peut vivre
rem n'importe ou et sur n'importe quel poste.
for %%I in ("%~dp0..") do set "ROOT=%%~fI"

rem Journaux dans le profil utilisateur : hors OneDrive (pas de synchronisation
rem inutile) et hors depot (qui est public).
set "LOGDIR=%LOCALAPPDATA%\GestionMails\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

set "LOG=%LOGDIR%\digest-cron.log"
set "CATCHUP_JSON=%LOGDIR%\catch-up-dernier.json"
set "SEND_JSON=%LOGDIR%\envoi-dernier.json"

rem Rotation par taille : au-dela de 5 Mo on archive (2 fichiers au maximum).
for %%F in ("%LOG%") do if %%~zF GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul 2>&1

echo. >> "%LOG%"
echo [%date% %time%] === declenchement du recap === >> "%LOG%"

call "%ROOT%\.claude\ensure-stack.cmd" "%LOG%"
if errorlevel 1 (
  echo [%date% %time%] ERREUR: pile indisponible, recap abandonne >> "%LOG%"
  exit /b 1
)

rem Lit CRON_SECRET depuis apps\web\.env
set "SECRET="
for /f "usebackq tokens=1,* delims==" %%a in ("%ROOT%\apps\web\.env") do (
  if /i "%%a"=="CRON_SECRET" set "SECRET=%%b"
)
if not defined SECRET (
  echo [%date% %time%] ERREUR: CRON_SECRET introuvable dans .env >> "%LOG%"
  exit /b 1
)

rem --- 1. Rattrapage des 3 derniers jours ---
rem La route produit les items de recap en SYNCHRONE : quand elle repond, les
rem DigestItem existent. Elle s'arrete a 240 s (Node coupe a 300 s) et renvoie
rem "done":false s'il reste du travail : on rappelle, 3 passes au maximum.
set "PASS=0"

:catchup_loop
set /a PASS+=1
curl -s -m 290 -H "Authorization: Bearer %SECRET%" "http://localhost:3000/api/catch-up/all" -o "%CATCHUP_JSON%"
rem Lu immediatement, hors de tout bloc parenthese : sinon %errorlevel% serait
rem developpe au parsing et une commande intercalee l'ecraserait.
set "CATCHUP_RC=%errorlevel%"

if not "%CATCHUP_RC%"=="0" (
  echo [%date% %time%] ERREUR: rattrapage injoignable ^(curl %CATCHUP_RC%^), on tente quand meme l'envoi >> "%LOG%"
  goto :send_digest
)

echo [%date% %time%] rattrapage passe %PASS% : >> "%LOG%"
type "%CATCHUP_JSON%" >> "%LOG%"
echo. >> "%LOG%"

findstr /c:"\"done\":true" "%CATCHUP_JSON%" >nul
if not errorlevel 1 goto :send_digest
if %PASS% LSS 3 goto :catchup_loop
echo [%date% %time%] AVERTISSEMENT: rattrapage incomplet apres 3 passes >> "%LOG%"

rem --- 2. Envoi du recap ---
rem sync=1 : on attend le vrai resultat d'envoi, sinon la route repond avant
rem que Resend n'ait rien recu et le journal ne prouve rien.
:send_digest
curl -s -m 290 -H "Authorization: Bearer %SECRET%" "http://localhost:3000/api/resend/digest/all?sync=1" -o "%SEND_JSON%"
set "SEND_RC=%errorlevel%"

echo [%date% %time%] envoi recap ^(curl %SEND_RC%^) : >> "%LOG%"
type "%SEND_JSON%" >> "%LOG%"
echo. >> "%LOG%"

if not "%SEND_RC%"=="0" (
  echo [%date% %time%] ERREUR: envoi du recap injoignable >> "%LOG%"
  endlocal
  exit /b 1
)

echo [%date% %time%] === termine === >> "%LOG%"
endlocal
exit /b 0
