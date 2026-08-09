@echo off
rem The double-clickable front door: everything from a cold machine to a
rem running voice line. Wraps scripts\start-jarvis.ps1 so the Desktop
rem shortcut has a .bat to point at and PowerShell's execution policy cannot
rem block it.
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-jarvis.ps1" %*
if errorlevel 1 (
  echo.
  echo ---------------------------------------------------------------
  echo Startup stopped with an error. The text above says why.
  echo ---------------------------------------------------------------
  pause
)

endlocal
