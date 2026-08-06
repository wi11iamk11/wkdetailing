<#
    check-servers.ps1 -- verify the two local services before you trust them.

    Answers the three questions that actually matter:
      1. Which transcription route does this whisper build really expose?
      2. Does Kokoro return raw PCM on /v1/audio/speech?
      3. Is Kokoro's torch actually on CUDA, or did it silently install a
         CPU-only wheel and get 10x slower with no error message?

    Run it from a normal (non-elevated) PowerShell window.
#>

param(
    [int]$WhisperPort = 2022,
    [int]$KokoroPort  = 8880,
    [string]$KokoroDir = "$env:USERPROFILE\kokoro-fastapi"
)

$ErrorActionPreference = "Continue"
$ok = $true

function Say($msg, $color = "Gray") { Write-Host $msg -ForegroundColor $color }

# --- 1. whisper -----------------------------------------------------------
Say "`n[1/3] whisper on port $WhisperPort" "Cyan"

# A quarter second of silence is enough to make a route answer.
$wav = Join-Path $env:TEMP "voice-line-probe.wav"
$sampleRate = 16000; $samples = $sampleRate / 4
$bytes = New-Object byte[] (44 + $samples * 2)
$hdr = [System.Text.Encoding]::ASCII
[void]$hdr.GetBytes("RIFF").CopyTo($bytes, 0)
[BitConverter]::GetBytes([int](36 + $samples * 2)).CopyTo($bytes, 4)
[void]$hdr.GetBytes("WAVEfmt ").CopyTo($bytes, 8)
[BitConverter]::GetBytes([int]16).CopyTo($bytes, 16)
[BitConverter]::GetBytes([int16]1).CopyTo($bytes, 20)
[BitConverter]::GetBytes([int16]1).CopyTo($bytes, 22)
[BitConverter]::GetBytes([int]$sampleRate).CopyTo($bytes, 24)
[BitConverter]::GetBytes([int]($sampleRate * 2)).CopyTo($bytes, 28)
[BitConverter]::GetBytes([int16]2).CopyTo($bytes, 32)
[BitConverter]::GetBytes([int16]16).CopyTo($bytes, 34)
[void]$hdr.GetBytes("data").CopyTo($bytes, 36)
[BitConverter]::GetBytes([int]($samples * 2)).CopyTo($bytes, 40)
[System.IO.File]::WriteAllBytes($wav, $bytes)

$route = $null
foreach ($candidate in @("/inference", "/v1/audio/transcriptions")) {
    $url = "http://127.0.0.1:$WhisperPort$candidate"
    try {
        $form = @{ file = Get-Item $wav; response_format = "json" }
        if ($candidate -like "/v1/*") { $form["model"] = "whisper-1" }
        $resp = Invoke-WebRequest -Uri $url -Method Post -Form $form -TimeoutSec 20
        if ($resp.StatusCode -eq 200) {
            Say "  OK   $candidate answered 200" "Green"
            if (-not $route) { $route = $candidate }
        }
    } catch {
        Say "  no   $candidate -> $($_.Exception.Message)" "DarkGray"
    }
}
if ($route) {
    Say "  ==> wire the client to $route" "Green"
} else {
    Say "  FAIL no transcription route answered on port $WhisperPort" "Red"
    Say "       Is whisper-server running? scripts\setup-servers.ps1 installs it." "Yellow"
    $ok = $false
}

# --- 2. kokoro ------------------------------------------------------------
Say "`n[2/3] kokoro on port $KokoroPort" "Cyan"
try {
    $body = @{ model = "kokoro"; input = "check"; voice = "bm_lewis"
               response_format = "pcm"; speed = 1.0 } | ConvertTo-Json
    $out = Join-Path $env:TEMP "voice-line-kokoro.pcm"
    Invoke-WebRequest -Uri "http://127.0.0.1:$KokoroPort/v1/audio/speech" -Method Post `
        -ContentType "application/json" -Body $body -OutFile $out -TimeoutSec 30
    $size = (Get-Item $out).Length
    if ($size -gt 1000) {
        $seconds = [math]::Round($size / 2 / 24000, 2)
        Say "  OK   returned $size bytes of PCM (~$seconds s at 24 kHz mono)" "Green"
    } else {
        Say "  FAIL returned only $size bytes" "Red"; $ok = $false
    }
} catch {
    Say "  FAIL $($_.Exception.Message)" "Red"
    Say "       Is kokoro-fastapi running on $KokoroPort?" "Yellow"
    $ok = $false
}

# --- 3. is kokoro's torch on the GPU? ------------------------------------
Say "`n[3/3] torch.cuda in the Kokoro environment" "Cyan"
$python = Join-Path $KokoroDir ".venv\Scripts\python.exe"
if (Test-Path $python) {
    & $python -c "import torch;print('torch',torch.__version__);print('cuda_available',torch.cuda.is_available());print('device',torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU ONLY')"
    if ($LASTEXITCODE -ne 0) { Say "  could not query torch" "Yellow" }
    Say "  If cuda_available is False but you have an Nvidia GPU, the GPU extra" "Yellow"
    Say "  installed a CPU-only wheel. Fix it with the exact CUDA wheel:" "Yellow"
    Say "    cd `"$KokoroDir`"; uv pip install torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124" "Yellow"
} else {
    Say "  skipped: no venv at $python" "DarkGray"
    Say "  (pass -KokoroDir if you installed it somewhere else)" "DarkGray"
}

Say ""
if ($ok) { Say "Both services answered." "Green"; exit 0 }
else     { Say "Something is not up. See above." "Red"; exit 1 }
