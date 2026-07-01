# Optional helper to run before resetting a laptop.
# Saves Windows edition/activation/OEM key status to the USB, then opens Reset this PC.

$ErrorActionPreference = 'Continue'
$UsbRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $UsbRoot 'logs'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

$Computer = $env:COMPUTERNAME
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath = Join-Path $LogDir "pre-reset-$Computer-$Stamp.txt"

Start-Transcript -Path $LogPath -Force

Write-Host '=== Windows edition ==='
Get-ComputerInfo | Select-Object CsName, WindowsProductName, WindowsVersion, OsHardwareAbstractionLayer | Format-List

Write-Host '=== Activation status ==='
cscript.exe //nologo "$env:windir\system32\slmgr.vbs" /xpr

Write-Host '=== Embedded OEM key, if present ==='
try {
    $key = (Get-CimInstance -Query 'select * from SoftwareLicensingService').OA3xOriginalProductKey
    if ([string]::IsNullOrWhiteSpace($key)) { 'No embedded OEM product key was returned.' } else { $key }
} catch {
    Write-Warning "Could not read embedded OEM key: $($_.Exception.Message)"
}

Write-Host '=== Windows Recovery Environment ==='
reagentc /info

Stop-Transcript

Write-Host "Saved pre-reset info to: $LogPath"
Write-Host 'Opening Reset this PC. Choose: Remove everything. Local reinstall is usually fine.'
Start-Process 'systemreset.exe' -ArgumentList '-factoryreset'
