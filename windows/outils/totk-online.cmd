@echo off
rem Tears of the Kingdom en ligne, prepare d'un coup par Home.
rem
rem Mets dans le meme dossier que ce fichier :
rem   - le mod en ligne : son dossier (avec romfs et/ou exefs dedans) ou son archive .zip ;
rem   - serveur.txt : une ligne, l'adresse du serveur (adresse:port) ;
rem   - prod.keys, les cles de ta console, si Home ne les a pas deja.
rem Puis double-clique : Home s'ouvre et te demande seulement ton jeu et sa mise a jour.
rem Home ne fournit ni jeu, ni cle, ni mod.
setlocal
set "HOMEEXE=%LOCALAPPDATA%\Programs\Home\Home.exe"
if not exist "%HOMEEXE%" (
  echo Home n'est pas installe sur ce PC. Installe-le d'abord : https://github.com/amas-cd/Home/releases
  pause
  exit /b 1
)
tasklist /FI "IMAGENAME eq Home.exe" 2>nul | find /I "Home.exe" >nul
if not errorlevel 1 (
  echo Home est deja ouvert. Ferme-le, puis relance ce fichier.
  pause
  exit /b 1
)
start "" "%HOMEEXE%" --totk-online "%~dp0."
