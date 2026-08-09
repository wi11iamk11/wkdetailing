<#
    start-jarvis.ps1 -- one command that gets from a cold machine to a running
    voice line, doing only the steps that still need doing.

    Everything here was previously a chain of manual commands, each of which
    fails in its own way and leaves you guessing which step you are on. The
    order is fixed by dependency:

        uv installed?  ->  servers installed?  ->  servers running?  ->  go

    Every stage is skipped when it is already satisfied, so the common case
    (everything installed, servers already up) falls straight through to the
    launch in about a second.

    Run from a normal, non-elevated PowerShell window. Nothing here needs
    Administrator -- the optional service install does, and is left alone.
#>

param(
    # Passed through to main.py, e.g. -Arguments "--voice elevenlabs"
    [string]$Arguments = "",
    [int]$WhisperPort = 2022,
    [int]$KokoroPort = 8880,
    [string]$ServerDir = "$env:USERPROFILE\voice-line-servers",
    # How long to wait for a freshly started server to answer. Generous
    # because the first Kokoro start is not just a process launch: it imports
    # torch and loads its voice models, which on a cold CPU-only box runs to
    # several minutes. Timing out early here looks identical to a crash and
    # sends you hunting for an error that was never written.
    [int]$ServerTimeoutSec = 420,
    # Install the servers without asking. Without this, a missing install
    # prompts first, because it is a long download.
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }
function Step($m) { Write-Host "`n$m" -ForegroundColor Cyan }

$voiceLineDir = Split-Path $PSScriptRoot -Parent

function Test-Port([int]$Port) {
    # A TCP connect is the cheapest "is anything listening" test, and unlike
    # an HTTP probe it does not care which routes the server exposes.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-Port([int]$Port, [string]$Name, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port $Port) {
            Say "  $Name is answering on port $Port" "Green"
            return $true
        }
        Start-Sleep -Milliseconds 750
    }
    Say "  $Name never answered on port $Port after $TimeoutSec seconds" "Red"
    return $false
}

# --- 1. uv ----------------------------------------------------------------
Step "[1/4] uv"
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Say "  already installed"
} else {
    Say "  not found, installing with winget..." "Yellow"
    winget install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements
    # winget writes the new PATH to the registry, but this process still has
    # the old one. Rebuild it in-process so uv is usable without reopening.
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        throw "uv still is not on PATH after installing. Close this window, open a new one, and run this script again."
    }
    Say "  installed" "Green"
}

# --- 2. the servers, on disk ---------------------------------------------
Step "[2/4] speech servers installed"
$startWhisper = Join-Path $ServerDir "start-whisper.cmd"
$startKokoro = Join-Path $ServerDir "start-kokoro.cmd"

if ((Test-Path $startWhisper) -and (Test-Path $startKokoro)) {
    Say "  found in $ServerDir"
} else {
    Say "  not installed in $ServerDir" "Yellow"
    if (-not $Yes) {
        Say "  Installing them downloads several GB (whisper, a model, Kokoro and PyTorch)." "Yellow"
        $answer = Read-Host "  Install now? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Say "`nStopped. Nothing was installed." "Yellow"
            Say "Re-run when you have time, or install them yourself with:" "Cyan"
            Say "  powershell -ExecutionPolicy Bypass -File scripts\setup-servers.ps1" "Cyan"
            exit 1
        }
    }
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "setup-servers.ps1")
    if ($LASTEXITCODE -ne 0) { throw "setup-servers.ps1 failed. See the output above." }
    if (-not ((Test-Path $startWhisper) -and (Test-Path $startKokoro))) {
        throw "setup-servers.ps1 finished but $ServerDir still has no launchers."
    }
}

# --- 3. the servers, running ---------------------------------------------
Step "[3/4] speech servers running"
$started = $false

if (Test-Port $WhisperPort) {
    Say "  whisper already up on port $WhisperPort" "Green"
} else {
    Say "  starting whisper..." "Yellow"
    # Their own windows, deliberately: they are long-running and their logs
    # are worth being able to look at when something misbehaves.
    Start-Process -FilePath $startWhisper -WorkingDirectory $ServerDir
    $started = $true
}

if (Test-Port $KokoroPort) {
    Say "  kokoro already up on port $KokoroPort" "Green"
} else {
    Say "  starting kokoro..." "Yellow"
    Start-Process -FilePath $startKokoro -WorkingDirectory $ServerDir
    $started = $true
}

if ($started) {
    Say "  waiting for them to come up (whisper loads its model first)..."
    $whisperOk = Wait-Port $WhisperPort "whisper" $ServerTimeoutSec
    $kokoroOk = Wait-Port $KokoroPort "kokoro" $ServerTimeoutSec
    if (-not ($whisperOk -and $kokoroOk)) {
        Say "`nA server did not start. Look at the window it opened -- the error is in there." "Red"
        Say "For a deeper check of both, run:" "Cyan"
        Say "  powershell -ExecutionPolicy Bypass -File scripts\check-servers.ps1" "Cyan"
        exit 1
    }
}

# --- 4. go ----------------------------------------------------------------
Step "[4/4] starting the voice line"
Set-Location $voiceLineDir
& (Join-Path $voiceLineDir "run-voice-line.bat") $Arguments
exit $LASTEXITCODE
