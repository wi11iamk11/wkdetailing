<#
    install-services.ps1 -- run whisper and Kokoro as real Windows services,
    so they survive reboots and restart themselves on a crash.

    MUST be run from an ELEVATED PowerShell window. Service installs always
    need Administrator; there is no way around it.

    The voice line itself is NOT a service and never should be. Nobody wants a
    24/7 open mic. Only the two servers become services.

    Two gotchas are handled here:

    1. LocalSystem does not inherit your user PATH. If the speech server used
       an ffmpeg-dependent conversion flag it would fail silently under the
       service account, so we do not pass one -- the client already sends
       16 kHz mono WAV. -AddFfmpegToSystemPath is there if you need it anyway.

    2. Re-running an install against an existing service can silently no-op on
       the arguments, because some tools only apply the command line at
       creation. So this script force-sets Application, AppParameters and
       AppDirectory on EVERY run, not just the first.
#>

param(
    [string]$InstallDir = "$env:USERPROFILE\voice-line-servers",
    [string]$KokoroDir  = "$env:USERPROFILE\kokoro-fastapi",
    [string]$Model      = "ggml-small.en.bin",
    [int]$WhisperPort   = 2022,
    [int]$KokoroPort    = 8880,
    [switch]$AddFfmpegToSystemPath,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

$admin = ([Security.Principal.WindowsPrincipal] `
          [Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    throw "Run this from an elevated PowerShell window (Run as Administrator)."
}

# --- nssm -----------------------------------------------------------------
$nssm = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
if (-not $nssm) {
    Say "Installing NSSM..." "Yellow"
    winget install --id NSSM.NSSM -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $nssm = (Get-Command nssm -ErrorAction SilentlyContinue)?.Source
}
if (-not $nssm) { throw "nssm not found on PATH after install. Install it and re-run." }
Say "nssm      $nssm"

$services = @("VoiceLineWhisper", "VoiceLineKokoro")

if ($Uninstall) {
    foreach ($svc in $services) {
        if (Get-Service $svc -ErrorAction SilentlyContinue) {
            & $nssm stop $svc confirm | Out-Null
            & $nssm remove $svc confirm | Out-Null
            Say "Removed $svc" "Green"
        }
    }
    exit 0
}

if ($AddFfmpegToSystemPath) {
    $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue)?.Source
    if ($ff) {
        $dir = Split-Path $ff
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($machinePath -notlike "*$dir*") {
            [Environment]::SetEnvironmentVariable("Path", "$machinePath;$dir", "Machine")
            Say "Added $dir to the SYSTEM path so LocalSystem can see ffmpeg" "Green"
        } else {
            Say "ffmpeg already on the system path" "Green"
        }
    } else {
        Say "ffmpeg not found on your user PATH; nothing to add" "Yellow"
    }
}

function Install-Svc {
    param($Name, $App, $Args, $Dir, $DisplayName)

    if (-not (Test-Path $App)) { throw "$Name: executable not found: $App" }

    if (-not (Get-Service $Name -ErrorAction SilentlyContinue)) {
        & $nssm install $Name $App | Out-Null
        Say "Created $Name" "Green"
    } else {
        & $nssm stop $Name confirm | Out-Null
        Say "Updating existing $Name" "Yellow"
    }

    # Force-set these every run. Creating a service that already exists is a
    # no-op on its arguments, which is exactly how you end up debugging a
    # service that is still running last week's command line.
    & $nssm set $Name Application       $App           | Out-Null
    & $nssm set $Name AppParameters     $Args          | Out-Null
    & $nssm set $Name AppDirectory      $Dir           | Out-Null
    & $nssm set $Name DisplayName       $DisplayName   | Out-Null
    & $nssm set $Name Start             SERVICE_AUTO_START | Out-Null
    & $nssm set $Name AppExit Default   Restart        | Out-Null
    & $nssm set $Name AppRestartDelay   5000           | Out-Null
    & $nssm set $Name AppStdout (Join-Path $InstallDir "$Name.out.log") | Out-Null
    & $nssm set $Name AppStderr (Join-Path $InstallDir "$Name.err.log") | Out-Null
    & $nssm set $Name AppRotateFiles    1              | Out-Null

    & $nssm start $Name | Out-Null
    Start-Sleep -Seconds 2
    $state = (Get-Service $Name).Status
    Say "$Name is $state" $(if ($state -eq "Running") { "Green" } else { "Red" })
}

$whisperExe = Join-Path $InstallDir "whisper\whisper-server.exe"
$modelPath  = Join-Path $InstallDir "whisper\models\$Model"
Install-Svc -Name "VoiceLineWhisper" -App $whisperExe `
    -Args "-m `"$modelPath`" --host 127.0.0.1 --port $WhisperPort -l en -t 4" `
    -Dir (Split-Path $whisperExe) -DisplayName "voice-line whisper.cpp server"

$kokoroPy = Join-Path $KokoroDir ".venv\Scripts\python.exe"
Install-Svc -Name "VoiceLineKokoro" -App $kokoroPy `
    -Args "-m uvicorn api.src.main:app --host 127.0.0.1 --port $KokoroPort" `
    -Dir $KokoroDir -DisplayName "voice-line Kokoro TTS server"

Say "`nVerify with: powershell -File scripts\check-servers.ps1" "Cyan"
Say "Remove with: powershell -File scripts\install-services.ps1 -Uninstall" "Cyan"
