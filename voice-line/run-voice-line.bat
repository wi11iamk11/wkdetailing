@echo off
setlocal
cd /d "%~dp0"

where uv >nul 2>nul
if errorlevel 1 (
  echo uv is not on PATH. Install it with:
  echo   powershell -c "irm https://astral.sh/uv/install.ps1 ^| iex"
  exit /b 1
)

if not exist ".venv" (
  echo Creating the Python 3.12 environment...
  uv venv --python 3.12 || exit /b 1
)

uv sync --quiet || exit /b 1
uv run python main.py %*
endlocal
