@echo off
setlocal
cd /d "%~dp0"

where uv >nul 2>nul
if errorlevel 1 (
  echo uv is not on PATH. Install it with:
  echo   powershell -c "irm https://astral.sh/uv/install.ps1 ^| iex"
  goto :fail
)

if not exist ".venv" (
  echo Creating the Python 3.12 environment...
  uv venv --python 3.12 || goto :fail
  echo.
  echo Installing dependencies. The first run downloads a few hundred MB and
  echo can take several minutes. Progress is shown below -- do not close this.
  echo.
  rem Deliberately NOT --quiet on the first run: a silent multi-minute wait is
  rem indistinguishable from a hang, and gets the window closed prematurely.
  uv sync || goto :fail
) else (
  uv sync --quiet || goto :fail
)
uv run python main.py %*
if errorlevel 1 goto :fail

endlocal
exit /b 0

:fail
rem Launched from the Desktop shortcut, this window closes the instant the
rem script ends -- taking the error with it and looking like "it just doesn't
rem start". Hold it open so the reason is readable.
echo.
echo ---------------------------------------------------------------
echo The voice line stopped with an error. The text above says why.
echo ---------------------------------------------------------------
pause
endlocal
exit /b 1
