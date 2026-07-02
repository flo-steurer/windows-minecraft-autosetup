<#
Fast path for existing Windows installs.

This does not reset Windows. It creates/updates the configured local admin and
player accounts, installs machine-level apps, and registers per-user Minecraft
setup. For the cleanest player environment, use a player account name that does
not already have a profile on the laptop.
#>

[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$ConfigPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptRoot {
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        return (Resolve-Path -LiteralPath $PackageRoot).Path
    }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if (-not $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Read-JsonConfig {
    param([string]$Root)

    $path = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $Root 'payload\config.json'
    }

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing config file: $path"
    }

    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-PlayerUserName {
    param([object]$Config)

    $windowsConfig = Get-PropertyValue -Object $Config -Name 'windows' -Default ([pscustomobject]@{})
    return [string](Get-PropertyValue -Object $windowsConfig -Name 'playerUserName' -Default 'Player')
}

function Get-UserProfilePath {
    param([string]$UserName)

    $candidate = Join-Path 'C:\Users' $UserName
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    return ''
}

function Get-LocalUserSid {
    param([string]$UserName)

    try {
        $escapedName = $UserName.Replace("'", "''")
        $account = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND Name='$escapedName'" -ErrorAction Stop | Select-Object -First 1
        if ($account) { return [string]$account.SID }
    } catch {
        Write-Warning "Could not resolve SID for local user $UserName`: $($_.Exception.Message)"
    }
    return ''
}

function Test-ConfigFlag {
    param(
        [object]$Object,
        [string]$Name,
        [bool]$Default
    )

    $value = Get-PropertyValue -Object $Object -Name $Name -Default $Default
    if ($value -is [bool]) { return $value }
    return ([string]$value).ToLowerInvariant() -eq 'true'
}

function Get-SystemDriveFreeBytes {
    try {
        $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        return [int64]$drive.FreeSpace
    } catch {
        return -1
    }
}

function Format-Bytes {
    param([int64]$Bytes)

    if ($Bytes -lt 0) { return 'unknown' }
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

function Remove-DirectoryContents {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    Write-Host "Cleaning $Label`: $Path"
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not remove $($item.FullName): $($_.Exception.Message)"
        }
    }
}

function Stop-ServiceIfPresent {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not stop service $Name`: $($_.Exception.Message)"
        }
    }
}

function Start-ServiceIfPresent {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Running') {
        try {
            Start-Service -Name $Name -ErrorAction Stop
        } catch {
            Write-Warning "Could not start service $Name`: $($_.Exception.Message)"
        }
    }
}

function Get-DestructiveCleanupConfig {
    param([object]$Config)

    return (Get-PropertyValue -Object $Config -Name 'destructiveCleanup' -Default ([pscustomobject]@{}))
}

function Test-DestructiveCleanupConfirmed {
    param([object]$DestructiveCleanup)

    $enabled = Test-ConfigFlag -Object $DestructiveCleanup -Name 'enabled' -Default $false
    $confirmation = [string](Get-PropertyValue -Object $DestructiveCleanup -Name 'confirmation' -Default '')
    return ($enabled -and $confirmation -eq 'DELETE_USER_DATA')
}

function Remove-KnownFolderContents {
    param(
        [string]$ProfilePath,
        [string[]]$FolderNames
    )

    foreach ($folderName in $FolderNames) {
        if ([string]::IsNullOrWhiteSpace($folderName)) { continue }
        $path = Join-Path $ProfilePath $folderName
        Remove-DirectoryContents -Path $path -Label "$ProfilePath\$folderName"
    }
}

function Remove-PlayerProfileIfRequested {
    param(
        [object]$Config,
        [string]$PlayerUser
    )

    $destructiveCleanup = Get-DestructiveCleanupConfig -Config $Config
    if (-not (Test-DestructiveCleanupConfirmed -DestructiveCleanup $destructiveCleanup)) {
        return
    }

    if (-not (Test-ConfigFlag -Object $destructiveCleanup -Name 'deleteExistingPlayerProfile' -Default $false)) {
        return
    }

    Write-Step "Deleting existing player profile for $PlayerUser"
    $sid = Get-LocalUserSid -UserName $PlayerUser
    if (-not [string]::IsNullOrWhiteSpace($sid)) {
        $profile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($profile) {
            if ($profile.Loaded) {
                throw "Cannot delete profile for $PlayerUser because it is currently loaded. Sign out that account first."
            }
            try {
                Remove-CimInstance -InputObject $profile -ErrorAction Stop
                Write-Host "Deleted Windows profile for $PlayerUser."
                return
            } catch {
                Write-Warning "Could not delete profile through Win32_UserProfile: $($_.Exception.Message)"
            }
        }
    }

    $profilePath = Get-UserProfilePath -UserName $PlayerUser
    if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
        try {
            Remove-Item -LiteralPath $profilePath -Recurse -Force -ErrorAction Stop
            Write-Host "Deleted profile folder: $profilePath"
        } catch {
            throw "Could not delete profile folder $profilePath`: $($_.Exception.Message)"
        }
    }
}

function Invoke-DestructiveUserDataCleanup {
    param(
        [object]$Config,
        [string]$PlayerUser
    )

    $destructiveCleanup = Get-DestructiveCleanupConfig -Config $Config
    if (-not (Test-DestructiveCleanupConfirmed -DestructiveCleanup $destructiveCleanup)) {
        Write-Host 'Destructive user-data cleanup is disabled. Set destructiveCleanup.enabled=true and confirmation=DELETE_USER_DATA to enable it.'
        return
    }

    Remove-PlayerProfileIfRequested -Config $Config -PlayerUser $PlayerUser

    if (-not (Test-ConfigFlag -Object $destructiveCleanup -Name 'deleteKnownUserDataFolders' -Default $false)) {
        return
    }

    Write-Step 'Deleting configured user data folders'
    $folders = @((Get-PropertyValue -Object $destructiveCleanup -Name 'knownUserDataFolders' -Default @('Desktop','Documents','Downloads','Pictures','Videos','Music')))
    $excludedUsers = @((Get-PropertyValue -Object $destructiveCleanup -Name 'excludeUsers' -Default @('Public','Default','Default User','All Users')))
    $userDirs = Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue

    foreach ($userDir in $userDirs) {
        if ($excludedUsers -contains $userDir.Name) {
            Write-Host "Skipping excluded profile: $($userDir.FullName)"
            continue
        }
        Remove-KnownFolderContents -ProfilePath $userDir.FullName -FolderNames $folders
    }
}

function Get-InstalledProgramEntries {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entries = @()
    foreach ($path in $paths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.DisplayName)) {
                $entries += $item
            }
        }
    }
    return @($entries)
}

function Invoke-UninstallCommand {
    param(
        [string]$DisplayName,
        [string]$Command,
        [bool]$AllowNonQuiet
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-Warning "No uninstall command found for $DisplayName."
        return
    }

    $commandToRun = $Command
    if ($commandToRun -match 'MsiExec\.exe' -or $commandToRun -match 'msiexec') {
        $commandToRun = $commandToRun -replace '/I', '/X'
        if ($commandToRun -notmatch '/q') {
            $commandToRun = "$commandToRun /qn /norestart"
        }
    } elseif (-not $AllowNonQuiet) {
        Write-Warning "Skipping $DisplayName because it has no quiet uninstall command. Command was: $Command"
        return
    }

    Write-Host "Uninstalling $DisplayName"
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $commandToRun) -Wait -PassThru
    if ($p.ExitCode -notin @(0, 3010, 1605, 1614)) {
        Write-Warning "Uninstall command for $DisplayName exited with code $($p.ExitCode)."
    }
}

function Invoke-ConfiguredUninstalls {
    param([object]$Config)

    $uninstall = Get-PropertyValue -Object $Config -Name 'uninstall' -Default ([pscustomobject]@{})
    if (-not (Test-ConfigFlag -Object $uninstall -Name 'enabled' -Default $false)) {
        Write-Host 'Configured app uninstall is disabled in payload\config.json.'
        return
    }

    $patterns = @((Get-PropertyValue -Object $uninstall -Name 'displayNamePatterns' -Default @()))
    if ($patterns.Count -eq 0) {
        Write-Host 'No uninstall displayNamePatterns are configured.'
        return
    }

    $allowNonQuiet = Test-ConfigFlag -Object $uninstall -Name 'allowNonQuietUninstallStrings' -Default $false
    Write-Step 'Uninstalling configured apps'
    $entries = Get-InstalledProgramEntries
    foreach ($entry in $entries) {
        $displayName = [string]$entry.DisplayName
        foreach ($pattern in $patterns) {
            if ($displayName -like [string]$pattern) {
                $quietCommand = [string]$entry.QuietUninstallString
                $normalCommand = [string]$entry.UninstallString
                $command = if (-not [string]::IsNullOrWhiteSpace($quietCommand)) { $quietCommand } else { $normalCommand }
                Invoke-UninstallCommand -DisplayName $displayName -Command $command -AllowNonQuiet $allowNonQuiet
                break
            }
        }
    }
}

function Invoke-ConservativeCleanup {
    param([object]$Config)

    $cleanup = Get-PropertyValue -Object $Config -Name 'cleanup' -Default ([pscustomobject]@{})
    $enabled = Test-ConfigFlag -Object $cleanup -Name 'enabled' -Default $true
    if (-not $enabled) {
        Write-Host 'Cleanup is disabled in payload\config.json.'
        return
    }

    Write-Step 'Conservative disk cleanup'
    $before = Get-SystemDriveFreeBytes
    Write-Host "Free space before cleanup: $(Format-Bytes -Bytes $before)"

    if (Test-ConfigFlag -Object $cleanup -Name 'clearWindowsTemp' -Default $true) {
        Remove-DirectoryContents -Path (Join-Path $env:WINDIR 'Temp') -Label 'Windows temp'
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'clearCurrentUserTemp' -Default $true) {
        Remove-DirectoryContents -Path $env:TEMP -Label 'current user temp'
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'clearAllUserTemp' -Default $true) {
        $userDirs = Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue
        foreach ($userDir in $userDirs) {
            $tempDir = Join-Path $userDir.FullName 'AppData\Local\Temp'
            Remove-DirectoryContents -Path $tempDir -Label "$($userDir.Name) temp"
        }
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'emptyRecycleBin' -Default $true) {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Host 'Emptied recycle bin.'
        } catch {
            Write-Warning "Could not empty recycle bin: $($_.Exception.Message)"
        }
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'clearWindowsUpdateDownloadCache' -Default $true) {
        Stop-ServiceIfPresent -Name 'wuauserv'
        Stop-ServiceIfPresent -Name 'bits'
        Remove-DirectoryContents -Path (Join-Path $env:WINDIR 'SoftwareDistribution\Download') -Label 'Windows Update download cache'
        Start-ServiceIfPresent -Name 'bits'
        Start-ServiceIfPresent -Name 'wuauserv'
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'clearDeliveryOptimizationCache' -Default $true) {
        Stop-ServiceIfPresent -Name 'DoSvc'
        Remove-DirectoryContents -Path 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache' -Label 'Delivery Optimization cache'
        Start-ServiceIfPresent -Name 'DoSvc'
    }

    if (Test-ConfigFlag -Object $cleanup -Name 'runComponentCleanup' -Default $false) {
        Write-Host 'Running Windows component cleanup. This can take a while.'
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "DISM component cleanup exited with code $LASTEXITCODE"
        }
    }

    $after = Get-SystemDriveFreeBytes
    Write-Host "Free space after cleanup: $(Format-Bytes -Bytes $after)"
    if ($before -ge 0 -and $after -ge 0) {
        Write-Host "Freed approximately: $(Format-Bytes -Bytes ($after - $before))"
    }
}

$root = Get-ScriptRoot
$logRoot = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("Reprovision-Existing-Windows-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Start-Transcript -Path $logPath -Force | Out-Null
try {
    if (-not (Test-IsAdmin)) {
        throw 'Run this script as Administrator.'
    }

    Write-Host "Package root: $root"
    Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $config = Read-JsonConfig -Root $root
    $playerUser = Get-PlayerUserName -Config $config

    Invoke-ConservativeCleanup -Config $config
    Invoke-DestructiveUserDataCleanup -Config $config -PlayerUser $playerUser
    Invoke-ConfiguredUninstalls -Config $config

    $playerProfile = Get-UserProfilePath -UserName $playerUser

    if (-not [string]::IsNullOrWhiteSpace($playerProfile)) {
        Write-Warning "The configured player profile already exists: $playerProfile"
        Write-Warning 'For the cleanest no-reset deployment, use a new playerUserName in payload\config.json or remove that old profile manually before running this.'
    } else {
        Write-Host "Configured player account $playerUser does not yet have a profile. First login will create a fresh profile."
    }

    $oobeApply = Join-Path $root 'OOBE-Apply.ps1'
    if (-not (Test-Path -LiteralPath $oobeApply)) {
        throw "Missing setup entry script: $oobeApply"
    }

    Write-Step 'Creating accounts and installing machine setup'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $oobeApply -PackageRoot $root
    if ($LASTEXITCODE -ne 0) {
        throw "OOBE-Apply.ps1 failed with exit code $LASTEXITCODE"
    }

    Write-Step 'Next step'
    Write-Host "Sign out, then log in as $playerUser. Windows will create the profile if needed, and Minecraft per-user setup will run at that login."
    Write-Host "Log saved to $logPath"
}
catch {
    Write-Error $_
    Write-Host "`nFAILED. Log saved to $logPath" -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
