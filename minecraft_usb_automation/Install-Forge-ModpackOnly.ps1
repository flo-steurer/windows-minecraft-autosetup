<#
Install only the Forge/modpack payload for the current Windows user.

This script does not install Minecraft Launcher, Java, Roblox Studio, create
accounts, or clean Windows. Run it while logged in as the Windows account that
will play Minecraft.
#>

[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$ConfigPath = '',
    [switch]$CleanMods
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$WarningsSeen = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-SetupWarning {
    param([string]$Message)
    $script:WarningsSeen.Add($Message) | Out-Null
    Write-Warning $Message
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

function Read-SetupConfig {
    param([string]$Root)

    $path = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $Root 'payload\config.json'
    }

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing config file: $path"
    }

    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        throw "Could not parse config file $path`: $($_.Exception.Message)"
    }
}

function Get-ModManifest {
    param([object]$Config)

    $mods = Get-PropertyValue -Object $Config -Name 'mods' -Default @()
    if ($null -eq $mods) { return @() }
    return @($mods)
}

function Get-ModFileName {
    param([object]$Mod)

    if ($Mod -is [string]) { return $Mod }
    return [string](Get-PropertyValue -Object $Mod -Name 'file' -Default '')
}

function Get-ModHash {
    param([object]$Mod)

    if ($Mod -is [string]) { return '' }
    return [string](Get-PropertyValue -Object $Mod -Name 'sha256' -Default '')
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing required folder: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $items = Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop
    foreach ($item in $items) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-InstalledProgramNames {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $names = @()
    foreach ($path in $paths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $displayName = [string](Get-PropertyValue -Object $item -Name 'DisplayName' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                $names += $displayName
            }
        }
    }
    return @($names | Select-Object -Unique)
}

function Test-MinecraftLauncherPresent {
    $installedNames = Get-InstalledProgramNames
    foreach ($name in $installedNames) {
        if ($name -like '*Minecraft Launcher*') {
            Write-Host "Detected Minecraft Launcher from installed programs: $name"
            return $true
        }
    }

    $shortcutRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    foreach ($root in $shortcutRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $shortcut = Get-ChildItem -LiteralPath $root -Filter '*Minecraft*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($shortcut) {
            Write-Host "Detected Minecraft Launcher shortcut: $($shortcut.FullName)"
            return $true
        }
    }

    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApp = Get-StartApps | Where-Object { $_.Name -like '*Minecraft*' } | Select-Object -First 1
        if ($startApp) {
            Write-Host "Detected Minecraft app registration: $($startApp.Name)"
            return $true
        }
    }

    return $false
}

function Test-Java8Present {
    $java = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($java) {
        Write-Host "Detected java.exe on PATH: $($java.Source)"
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $versionOutput = & $java.Source -version 2>&1
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $versionText = ($versionOutput | ForEach-Object { $_.ToString() } | Out-String).Trim()
        if ($versionText) { Write-Host $versionText }
        if ($versionText -match 'version "1\.8\.' -or $versionText -match 'version "8') {
            return $true
        }
        Write-SetupWarning 'java.exe exists, but it does not look like Java 8. Minecraft 1.8.9 Forge may still work with the Launcher runtime, but Java 8 is safest for old Forge.'
    }

    $commonRoots = @(
        "$env:ProgramFiles\Java",
        "${env:ProgramFiles(x86)}\Java",
        "$env:ProgramFiles\Eclipse Adoptium",
        "${env:ProgramFiles(x86)}\Eclipse Adoptium"
    )
    foreach ($root in $commonRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        $java8 = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*1.8*' -or $_.Name -like '*8*' } |
            Select-Object -First 1
        if ($java8) {
            Write-Host "Detected possible Java 8 installation: $($java8.FullName)"
            return $true
        }
    }

    return $false
}

function Validate-Payload {
    param(
        [string]$Root,
        [object]$Config,
        [string]$VersionId
    )

    Write-Step 'Validating Forge/modpack payload'

    $payload = Join-Path $Root 'payload'
    if (-not (Test-Path -LiteralPath $payload)) {
        throw "Missing required payload folder: $payload"
    }

    $forgeTemplate = Join-Path $payload 'forge-template'
    $versionsSource = Join-Path $forgeTemplate 'versions'
    $librariesSource = Join-Path $forgeTemplate 'libraries'
    $assetsSource = Join-Path $forgeTemplate 'assets'
    $modsSource = Join-Path $payload 'mods'

    if (-not (Test-Path -LiteralPath (Join-Path $versionsSource $VersionId))) {
        throw "Missing Forge version folder: $(Join-Path $versionsSource $VersionId)"
    }
    if (-not (Test-Path -LiteralPath $librariesSource)) {
        throw "Missing Forge/Minecraft libraries folder: $librariesSource"
    }
    if (-not (Test-Path -LiteralPath $modsSource)) {
        throw "Missing mods folder: $modsSource"
    }

    $minecraftConfig = Get-PropertyValue -Object $Config -Name 'minecraft' -Default ([pscustomobject]@{})
    if ((Test-ConfigFlag -Object $minecraftConfig -Name 'requireAssets' -Default $false) -and -not (Test-Path -LiteralPath $assetsSource)) {
        throw "Config requires assets, but this folder is missing: $assetsSource"
    }

    $mods = Get-ModManifest -Config $Config
    if ($mods.Count -gt 0) {
        foreach ($mod in $mods) {
            $fileName = Get-ModFileName -Mod $mod
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                throw 'A mod entry is missing its file name.'
            }

            $path = Join-Path $modsSource $fileName
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Expected mod is missing: $path"
            }

            $expectedHash = Get-ModHash -Mod $mod
            if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
                    throw "SHA256 mismatch for $fileName. Expected $expectedHash but found $actualHash"
                }
            }
        }
    } else {
        $jarFiles = @(Get-ChildItem -LiteralPath $modsSource -Filter '*.jar' -File -ErrorAction SilentlyContinue)
        if ($jarFiles.Count -eq 0) {
            throw "No mod .jar files were found in $modsSource"
        }
        Write-SetupWarning 'No mods are listed in config.json; all .jar files in payload\mods will be copied.'
    }

    Write-Host 'Payload validation passed.'
}

function Backup-ExistingModsIfRequested {
    param([string]$ModsDir)

    if (-not $CleanMods) { return }
    if (-not (Test-Path -LiteralPath $ModsDir)) { return }

    $existing = @(Get-ChildItem -LiteralPath $ModsDir -File -Filter '*.jar' -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) { return }

    $backup = Join-Path (Split-Path -Parent $ModsDir) ("mods-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($file in $existing) {
        Move-Item -LiteralPath $file.FullName -Destination $backup -Force
    }
    Write-Host "Moved existing mod .jar files to: $backup"
}

function Copy-Mods {
    param(
        [string]$ModsSource,
        [string]$ModsDestination,
        [object]$Config
    )

    New-Item -ItemType Directory -Force -Path $ModsDestination | Out-Null
    Backup-ExistingModsIfRequested -ModsDir $ModsDestination

    $mods = Get-ModManifest -Config $Config
    if ($mods.Count -gt 0) {
        foreach ($mod in $mods) {
            $fileName = Get-ModFileName -Mod $mod
            Copy-Item -LiteralPath (Join-Path $ModsSource $fileName) -Destination $ModsDestination -Force
            Write-Host "Copied mod: $fileName"
        }
        return
    }

    $jarFiles = @(Get-ChildItem -LiteralPath $ModsSource -Filter '*.jar' -File -ErrorAction Stop)
    foreach ($jar in $jarFiles) {
        Copy-Item -LiteralPath $jar.FullName -Destination $ModsDestination -Force
        Write-Host "Copied mod: $($jar.Name)"
    }
}

function Ensure-LauncherProfile {
    param(
        [Parameter(Mandatory=$true)][string]$MinecraftDir,
        [Parameter(Mandatory=$true)][string]$VersionId,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Args
    )

    $profilePath = Join-Path $MinecraftDir 'launcher_profiles.json'
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $profileKey = 'forge_modpack'

    if (Test-Path -LiteralPath $profilePath) {
        try {
            $json = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        } catch {
            $backup = "$profilePath.broken.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Copy-Item -LiteralPath $profilePath -Destination $backup -Force
            Write-SetupWarning "launcher_profiles.json was unreadable. Backed it up to $backup and recreated it."
            $json = [pscustomobject]@{}
        }
    } else {
        Write-SetupWarning "launcher_profiles.json does not exist yet. This is normal if Minecraft Launcher has never been opened for $env:USERNAME."
        $json = [pscustomobject]@{}
    }

    if (-not $json.PSObject.Properties['profiles']) {
        Add-Member -InputObject $json -MemberType NoteProperty -Name 'profiles' -Value ([pscustomobject]@{})
    }

    $profile = [pscustomobject]@{
        name          = $Name
        type          = 'custom'
        created       = $now
        lastUsed      = $now
        lastVersionId = $VersionId
        javaArgs      = $Args
    }

    if ($json.profiles.PSObject.Properties[$profileKey]) {
        $json.profiles.$profileKey = $profile
    } else {
        Add-Member -InputObject $json.profiles -MemberType NoteProperty -Name $profileKey -Value $profile
    }

    $json | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $profilePath -Encoding UTF8
    Write-Host "Created/updated Minecraft Launcher profile: $Name"
}

$root = Get-ScriptRoot
$logRoot = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("Install-Forge-ModpackOnly-$env:COMPUTERNAME-$env:USERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Package root: $root"
    Write-Host "Running as Windows user: $env:USERNAME"
    Write-Host 'This script configures the current user profile only.'

    $config = Read-SetupConfig -Root $root
    $minecraftConfig = Get-PropertyValue -Object $config -Name 'minecraft' -Default ([pscustomobject]@{})
    $profileName = [string](Get-PropertyValue -Object $minecraftConfig -Name 'profileName' -Default 'Forge Modpack')
    $forgeVersionId = [string](Get-PropertyValue -Object $minecraftConfig -Name 'versionId' -Default '1.8.9-forge1.8.9-11.15.1.2318-1.8.9')
    $javaArgs = [string](Get-PropertyValue -Object $minecraftConfig -Name 'javaArgs' -Default '-Xmx2G -Xms1G')

    Write-Step 'Checking prerequisites'
    if (-not (Test-MinecraftLauncherPresent)) {
        Write-SetupWarning 'Minecraft Launcher was not detected. This script will still copy Forge/mod files, but the player cannot launch them until Minecraft Launcher is installed.'
    }

    if (-not (Test-Java8Present)) {
        Write-SetupWarning 'Java 8 was not detected. The modern Minecraft Launcher may provide its own Java runtime, but old Forge 1.8.9 is most reliable with Java 8 installed.'
    }

    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'Could not resolve the current user APPDATA folder.'
    }
    $minecraftDir = Join-Path $appData '.minecraft'
    if (-not (Test-Path -LiteralPath $minecraftDir)) {
        Write-SetupWarning "%APPDATA%\.minecraft does not exist yet for $env:USERNAME. Creating it now. If Launcher behaves oddly, open Minecraft Launcher once and rerun this script."
        New-Item -ItemType Directory -Force -Path $minecraftDir | Out-Null
    }

    Validate-Payload -Root $root -Config $config -VersionId $forgeVersionId

    $payload = Join-Path $root 'payload'
    $forgeTemplate = Join-Path $payload 'forge-template'
    $versionsSource = Join-Path $forgeTemplate 'versions'
    $librariesSource = Join-Path $forgeTemplate 'libraries'
    $assetsSource = Join-Path $forgeTemplate 'assets'
    $modsSource = Join-Path $payload 'mods'

    Write-Step 'Copying Forge version files'
    Copy-DirectoryContents -Source $versionsSource -Destination (Join-Path $minecraftDir 'versions')

    Write-Step 'Copying Forge/Minecraft libraries'
    Copy-DirectoryContents -Source $librariesSource -Destination (Join-Path $minecraftDir 'libraries')

    if (Test-ConfigFlag -Object $minecraftConfig -Name 'copyAssets' -Default $true) {
        if (Test-Path -LiteralPath $assetsSource) {
            Write-Step 'Copying Minecraft assets'
            Copy-DirectoryContents -Source $assetsSource -Destination (Join-Path $minecraftDir 'assets')
        } else {
            Write-SetupWarning "Assets folder not found at $assetsSource. The Launcher may need internet access on first run."
        }
    }

    Write-Step 'Copying mods'
    Copy-Mods -ModsSource $modsSource -ModsDestination (Join-Path $minecraftDir 'mods') -Config $config

    Write-Step 'Creating Minecraft Launcher profile'
    Ensure-LauncherProfile -MinecraftDir $minecraftDir -VersionId $forgeVersionId -Name $profileName -Args $javaArgs

    Write-Step 'Summary'
    Write-Host "Minecraft folder: $minecraftDir"
    Write-Host "Forge version id: $forgeVersionId"
    Write-Host "Launcher profile: $profileName"
    if ($WarningsSeen.Count -gt 0) {
        Write-Host "`nCompleted with warnings:" -ForegroundColor Yellow
        foreach ($warning in $WarningsSeen) {
            Write-Host "- $warning" -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Completed without warnings.' -ForegroundColor Green
    }
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
