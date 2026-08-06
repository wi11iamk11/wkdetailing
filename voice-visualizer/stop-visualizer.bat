@echo off
REM ==========================================================================
REM  Stop the visualizer server by finding the process actually holding the
REM  port and killing exactly that PID.
REM
REM  Deliberately NOT a pattern kill. A stale server holding the port keeps
REM  answering with old code, and a broad `taskkill /im python.exe` would take
REM  down every other Python you have running -- the voice line included.
REM
REM   stop-visualizer.bat          stops the real server (8777)
REM   stop-visualizer.bat mock     stops the mock server (8778)
REM   stop-visualizer.bat all      stops both
REM ==========================================================================
setlocal EnableDelayedExpansion

if /i "%~1"=="all" (
  call :kill_port 8777
  call :kill_port 8778
  goto :done
)
if /i "%~1"=="mock" ( call :kill_port 8778 & goto :done )
call :kill_port 8777

:done
endlocal
exit /b 0

:kill_port
set "FOUND="
for /f "tokens=5" %%P in ('netstat -ano ^| findstr /r /c:"TCP.*:%1 .*LISTENING"') do (
  if not defined FOUND (
    set "FOUND=%%P"
    echo Stopping the server on port %1 ^(PID %%P^)
    taskkill /PID %%P /F >nul 2>nul
  )
)
if not defined FOUND echo Nothing is listening on port %1
exit /b 0
