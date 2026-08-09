<#
    setup-servers.ps1 -- install the two local services the voice line rides on.

      whisper.cpp server  port 2022  small English model, CUDA if you have an
                                     Nvidia GPU, plain CPU otherwise
      kokoro-fastapi      port 8880  local TTS

    Run from a NORMAL PowerShell window (no admin needed). Installing them as
    Windows services is a separate, elevated step: scripts\install-services.ps1

    Nothing here is destructive: it skips anything already present, and it
    never overwrites a model or a checkout you already have.
#>

param(
    [string]$InstallDir  = "$env:USERPROFILE\voice-line-servers",
    [string]$KokoroDir   = "$env:USERPROFILE\kokoro-fastapi",
    [string]$Model       = "ggml-small.en.bin",
    [int]$WhisperPort    = 2022,
    [int]$KokoroPort     = 8880,
    [string]$TorchCuda   = "cu124",
    [string]$TorchVersion = "2.6.0",
    [switch]$ForceCpu,
    [switch]$SkipWhisper,
    [switch]$SkipKokoro
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }
function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

# --- prerequisites --------------------------------------------------------
Step "Prerequisites"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Say "Installing uv..." "Yellow"
    powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
Say "uv        $(uv --version)"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Say "Installing ffmpeg (needed to decode and master ElevenLabs audio)..." "Yellow"
    winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements
    Say "Open a new shell afterwards so ffmpeg lands on PATH." "Yellow"
} else {
    Say "ffmpeg    on PATH"
}

$hasNvidia = $false
if (-not $ForceCpu) {
    $hasNvidia = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
}
Say ("gpu       " + $(if ($hasNvidia) { "Nvidia detected, using CUDA builds" } else { "CPU builds" }))

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

# --- whisper.cpp ----------------------------------------------------------
if (-not $SkipWhisper) {
    Step "whisper.cpp server (port $WhisperPort)"

    $whisperDir = Join-Path $InstallDir "whisper"
    $serverExe  = Join-Path $whisperDir "whisper-server.exe"

    if (Test-Path $serverExe) {
        Say "Already installed at $serverExe" "Green"
    } else {
        New-Item -ItemType Directory -Force -Path $whisperDir | Out-Null
        Say "Looking up the latest whisper.cpp release..."
        $rel = Invoke-RestMethod "https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest" `
               -Headers @{ "User-Agent" = "voice-line-setup" }

        # Asset names change between releases, so match on a pattern and show
        # what was found if nothing matches, rather than hardcoding a URL that
        # rots.
        $pattern = if ($hasNvidia) { "*cublas*bin-x64*.zip" } else { "*bin-x64*.zip" }
        $asset = $rel.assets | Where-Object { $_.name -like $pattern -and
                                              ($hasNvidia -or $_.name -notlike "*cublas*") } |
                 Select-Object -First 1
        if (-not $asset) {
            Say "No asset matched '$pattern' in release $($rel.tag_name). Assets were:" "Red"
            $rel.assets | ForEach-Object { Say "  $($_.name)" "DarkGray" }
            throw "Pick one manually and unzip it into $whisperDir"
        }

        $zip = Join-Path $env:TEMP $asset.name
        Say "Downloading $($asset.name)..."
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $whisperDir -Force

        # Release zips nest the binaries a folder or two deep; flatten them.
        $found = Get-ChildItem -Path $whisperDir -Recurse -Filter "whisper-server.exe" |
                 Select-Object -First 1
        if (-not $found) { throw "whisper-server.exe not found inside $($asset.name)" }
        if ($found.DirectoryName -ne $whisperDir) {
            Copy-Item "$($found.DirectoryName)\*" $whisperDir -Recurse -Force
        }
        Say "Installed $serverExe" "Green"
    }

    $modelDir  = Join-Path $whisperDir "models"
    $modelPath = Join-Path $modelDir $Model
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    if (Test-Path $modelPath) {
        Say "Model already present: $modelPath" "Green"
    } else {
        Say "Downloading $Model (about 460 MB)..."
        Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$Model" `
            -OutFile $modelPath
        Say "Model at $modelPath" "Green"
    }

    # A start script, so the service install and manual runs use identical args.
    # Note: no --convert flag. We always send 16 kHz mono WAV, and --convert
    # shells out to ffmpeg, which the LocalSystem service account cannot see
    # on your user PATH.
    $startWhisper = Join-Path $InstallDir "start-whisper.cmd"
    @"
@echo off
"$serverExe" -m "$modelPath" --host 127.0.0.1 --port $WhisperPort -l en -t 4 -pc
"@ | Set-Content -Path $startWhisper -Encoding ASCII
    Say "Start it with: $startWhisper" "Green"
}

# --- kokoro-fastapi -------------------------------------------------------
if (-not $SkipKokoro) {
    Step "kokoro-fastapi (port $KokoroPort)"

    if (Test-Path (Join-Path $KokoroDir ".git")) {
        Say "Checkout already at $KokoroDir" "Green"
    } else {
        Say "Cloning kokoro-fastapi..."
        git clone https://github.com/remsky/Kokoro-FastAPI.git $KokoroDir
    }

    Push-Location $KokoroDir
    try {
        if (-not (Test-Path ".venv")) { uv venv --python 3.12 }
        Say "Installing dependencies..."

        # pyopenjtalk is skipped deliberately. Kokoro depends on misaki[ja]
        # for Japanese, which pulls pyopenjtalk -- published as source only,
        # so Windows tries to compile it and fails asking for Visual C++ and
        # CMake. pyopenjtalk-plus is a fork of the same library published
        # with wheels (cp39-cp314) that installs under the same `pyopenjtalk`
        # module name, so the import still resolves if Kokoro ever reaches
        # for it.
        uv sync --no-install-package pyopenjtalk
        if ($LASTEXITCODE -ne 0) {
            throw "uv sync failed in $KokoroDir. Kokoro will not start until this succeeds."
        }

        uv pip install pyopenjtalk-plus
        if ($LASTEXITCODE -ne 0) {
            Say "pyopenjtalk-plus did not install. Kokoro should still serve English." "Yellow"
        }

        # Without this the script used to sail past a failed sync and write a
        # launcher pointing at an environment with no uvicorn in it, which
        # surfaces much later as "No module named uvicorn".
        $uvicornProbe = & ".\.venv\Scripts\python.exe" -c "import uvicorn" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "uvicorn is missing from $KokoroDir\.venv despite a clean sync: $uvicornProbe"
        }

        if ($hasNvidia) {
            # THE SILENT ONE. `uv pip install -e ".[gpu]"` runs in uv's
            # pip-compatible legacy mode, which ignores the project's custom
            # PyTorch CUDA index routing, so it can install a CPU-only torch
            # and say nothing. `uv sync --extra gpu` can resolve wrong too.
            # Installing the exact pinned CUDA wheel straight from the PyTorch
            # index is the only reliable way.
            Say "Installing torch $TorchVersion+$TorchCuda from the PyTorch CUDA index..." "Yellow"
            uv pip install "torch==$TorchVersion" --index-url "https://download.pytorch.org/whl/$TorchCuda"

            Say "Verifying CUDA is actually active..."
            $probe = & ".\.venv\Scripts\python.exe" -c "import torch;print(torch.cuda.is_available())"
            if ($probe -match "True") {
                Say "torch.cuda.is_available() = True" "Green"
            } else {
                Say "torch.cuda.is_available() = False -- Kokoro will run on CPU," "Red"
                Say "10 to 14 times slower, and nothing else will tell you." "Red"
                Say "Try a different CUDA build, e.g. -TorchCuda cu121" "Yellow"
            }
        }
    } finally {
        Pop-Location
    }

    $startKokoro = Join-Path $InstallDir "start-kokoro.cmd"
    @"
@echo off
cd /d "$KokoroDir"
set USE_GPU=$(if ($hasNvidia) { "true" } else { "false" })
"$KokoroDir\.venv\Scripts\python.exe" -m uvicorn api.src.main:app --host 127.0.0.1 --port $KokoroPort
"@ | Set-Content -Path $startKokoro -Encoding ASCII
    Say "Start it with: $startKokoro" "Green"
}

Step "Next"
Say "1. Start both servers (the two .cmd files in $InstallDir)."
Say "2. Verify them:  scripts\check-servers.ps1"
Say "3. Launch:       run-voice-line.bat"
Say "Optional, survives reboots: scripts\install-services.ps1 (elevated)."
