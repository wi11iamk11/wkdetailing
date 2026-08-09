<#
    install-shortcut.ps1 -- put a JARVIS shortcut on the Desktop that launches
    the voice line.

    Does NOT need Administrator: this only writes a .lnk into your own Desktop
    folder. (install-services.ps1 is the one that needs elevation.)

    The shortcut points at start-jarvis.bat rather than run-voice-line.bat:
    the voice line is useless without the two speech servers, so the icon has
    to bring those up too or it just fails on a cold machine. A console window
    stays open either way, which the voice line needs -- you type into it as
    well as talk to it.

    Two gotchas are handled here:

    1. The Desktop is not always "$env:USERPROFILE\Desktop". OneDrive Known
       Folder Move redirects it to "$env:USERPROFILE\OneDrive\Desktop", and on
       a managed machine it can be a network path. GetFolderPath('Desktop')
       asks Windows where the Desktop actually is, which is the only answer
       that is right on every box.

    2. There is no built-in cmdlet that writes a .lnk. The WScript.Shell COM
       object is still the supported way to do it from PowerShell.
#>

param(
    [string]$Name = "JARVIS",
    # Extra arguments passed straight through to main.py, e.g.
    #   -Arguments "--voice elevenlabs"
    #   -Arguments "--ptt"
    [string]$Arguments = "",
    # Optional custom icon. Without one the shortcut inherits the .bat icon.
    # Accepts "path\to\icon.ico" or "path\to\file.dll,3".
    [string]$IconPath = "",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# Resolve the launcher relative to this script, so the shortcut is correct no
# matter where the repo lives or which directory you run this from.
$voiceLineDir = Split-Path $PSScriptRoot -Parent
$launcher     = Join-Path $voiceLineDir "start-jarvis.bat"

$desktop  = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { throw "Could not resolve your Desktop folder." }
$linkPath = Join-Path $desktop "$Name.lnk"

if ($Uninstall) {
    if (Test-Path $linkPath) {
        Remove-Item $linkPath -Force
        Say "Removed $linkPath" "Green"
    } else {
        Say "Nothing to remove: no shortcut at $linkPath" "Yellow"
    }
    exit 0
}

if (-not (Test-Path $launcher)) {
    throw "Launcher not found: $launcher (is this script still inside voice-line\scripts?)"
}

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($linkPath)
$shortcut.TargetPath       = $launcher
$shortcut.Arguments        = $Arguments
$shortcut.WorkingDirectory = $voiceLineDir
$shortcut.Description      = "Start the JARVIS voice line"
if ($IconPath) { $shortcut.IconLocation = $IconPath }
$shortcut.Save()

Say "Created $linkPath" "Green"
Say "  target    $launcher"
if ($Arguments) { Say "  arguments $Arguments" }
Say "`nDouble-click it to start. It brings the speech servers up itself." "Cyan"
Say "Remove the shortcut with:" "Cyan"
Say "  powershell -File scripts\install-shortcut.ps1 -Uninstall" "Cyan"
