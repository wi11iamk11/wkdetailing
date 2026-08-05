@echo off
setlocal

rem Always run from the folder this file is in, no matter where it's launched from.
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo Canvas Organizer needs Node.js, which isn't installed ^(or isn't on your PATH^).
  echo.
  echo Get it here, then re-run this file:
  echo   https://nodejs.org
  echo   ^(pick the LTS version, and use the default options during install^)
  echo.
  pause
  exit /b 1
)

if not exist "server.js" (
  echo.
  echo Could not find server.js next to Start.bat.
  echo Keep Start.bat inside the canvas-organizer folder — don't move it out on its own.
  echo.
  pause
  exit /b 1
)

if not defined PORT set PORT=4173

echo.
echo Starting Canvas Organizer on http://127.0.0.1:%PORT%
echo Your browser will open automatically in a couple of seconds.
echo.
echo Keep this window open while you use the app — closing it stops the app.
echo.

rem Give the server a moment to start listening before opening the browser.
start /min "" cmd /c "timeout /t 2 /nobreak >nul & start http://127.0.0.1:%PORT%"

node server.js

echo.
echo Canvas Organizer has stopped.
pause
