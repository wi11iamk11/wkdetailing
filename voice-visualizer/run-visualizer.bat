@echo off
REM ==========================================================================
REM  voice-visualizer launcher -- double-click this.
REM
REM   run-visualizer.bat          the real bus, port 8777
REM   run-visualizer.bat mock     the scripted loop, port 8778 (bus untouched)
REM
REM  Starts the server in the background if the port is not already answering,
REM  then opens a Chrome kiosk on a throwaway profile so no tabs, extensions or
REM  logged-in sessions ride along. Closing the kiosk with Alt+F4 leaves the
REM  server warm for next time.
REM ==========================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "MODE=%~1"
if /i "%MODE%"=="mock" (
  set "PORT=8778"
  set "ARGS=--mock"
  set "TITLE=voice-visualizer [MOCK]"
) else (
  set "PORT=8777"
  set "ARGS="
  set "TITLE=voice-visualizer"
)
set "URL=http://127.0.0.1:%PORT%/"
set "LOG=%TEMP%\voice-visualizer-%PORT%.log"
set "PROFILE=%TEMP%\voice-visualizer-profile-%PORT%"

REM ---- find python --------------------------------------------------------
set "PY="
where pythonw.exe >nul 2>nul && set "PY=pythonw.exe"
if not defined PY where python.exe >nul 2>nul && set "PY=python.exe"
if not defined PY (
  echo Python 3 was not found on PATH.
  echo Install it from https://python.org or the Microsoft Store, then re-run.
  pause
  exit /b 1
)

REM ---- start the server only if the port is not already answering ---------
call :port_open %PORT%
if errorlevel 1 (
  echo Starting %TITLE% on port %PORT%
  echo Log: %LOG%
  powershell -NoProfile -Command ^
    "Start-Process -FilePath '%PY%' -ArgumentList '\"%~dp0server.py\"','%ARGS%' -WindowStyle Hidden -RedirectStandardOutput '%LOG%' -RedirectStandardError '%LOG%.err'"
  for /l %%i in (1,1,30) do (
    call :port_open %PORT%
    if not errorlevel 1 goto :ready
    timeout /t 1 /nobreak >nul
  )
  echo Server did not come up. Check %LOG% and %LOG%.err
  pause
  exit /b 1
) else (
  echo Server already running on port %PORT%
)
:ready

REM ---- Chrome kiosk, throwaway profile ------------------------------------
set "CHROME="
for %%P in (
  "%ProgramFiles%\Google\Chrome\Application\chrome.exe"
  "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
  "%LocalAppData%\Google\Chrome\Application\chrome.exe"
  "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
) do if not defined CHROME if exist %%~P set "CHROME=%%~P"

if defined CHROME (
  start "" "%CHROME%" --kiosk --user-data-dir="%PROFILE%" ^
    --no-first-run --no-default-browser-check --disable-session-crashed-bubble ^
    --disable-infobars --hide-crash-restore-bubble --autoplay-policy=no-user-gesture-required ^
    "%URL%"
) else (
  echo Chrome was not found. Opening your default browser instead --
  echo press F11 once it loads to go fullscreen.
  start "" "%URL%"
)

endlocal
exit /b 0

REM ---- helper: is a TCP port accepting connections? -----------------------
:port_open
powershell -NoProfile -Command ^
  "try{$c=New-Object Net.Sockets.TcpClient;$c.Connect('127.0.0.1',%1);$c.Close();exit 0}catch{exit 1}" >nul 2>nul
exit /b %errorlevel%
