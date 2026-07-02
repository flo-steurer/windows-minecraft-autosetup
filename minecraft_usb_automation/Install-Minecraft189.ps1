<#
Reusable Minecraft Java modpack installer for reset/OOBE USB workflows.

Recommended deployment:
  1. Reset Windows from Settings > System > Recovery > Reset this PC.
  2. During OOBE, apply a provisioning package that runs OOBE-Apply.ps1.
  3. Log in as the player account once; the per-user phase installs the modpack.

Payload is controlled by payload\config.json. Keep real secrets and licensed/binary
payloads out of a public repo.
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto','Machine','User')]
    [string]$Mode = 'Auto',

    [string]$PackageRoot = '',

    [string]$ConfigPath = '',

    [string]$ProfileName = '',

    [string]$ForgeVersionId = '',

    [string]$JavaArgs = '',

    [string]$SetupVersion = '',

    [switch]$SkipLauncherInstall,

    [switch]$SkipRegisterUserSetup,

    [switch]$CleanMods
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

function Test-IsSystemContext {
    return ([Security.Principal.WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM')
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

function Read-SetupConfig {
    param([string]$Root)

    $path = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $Root 'payload\config.json'
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "No config file found at $path. Using built-in defaults."
        return [pscustomobject]@{}
    }

    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        throw "Could not parse config file $path`: $($_.Exception.Message)"
    }
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

function Invoke-External {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Host "Running: $FilePath $($ArgumentList -join ' ')"
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    if ($AllowedExitCodes -notcontains $p.ExitCode) {
        throw "Command failed with exit code $($p.ExitCode): $FilePath $($ArgumentList -join ' ')"
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

function Validate-Payload {
    param(
        [string]$Root,
        [object]$Config,
        [string]$VersionId
    )

    Write-Step 'Validating payload'

    $payload = Join-Path $Root 'payload'
    if (-not (Test-Path -LiteralPath $payload)) {
        throw "Missing required payload folder: $payload"
    }

    $forgeTemplate = Join-Path $payload 'forge-template'
    $versionsSource = Join-Path $forgeTemplate 'versions'
    $librariesSource = Join-Path $forgeTemplate 'libraries'
    $assetsSource = Join-Path $forgeTemplate 'assets'

    if (-not (Test-Path -LiteralPath (Join-Path $versionsSource $VersionId))) {
        throw "Missing Forge version folder: $(Join-Path $versionsSource $VersionId)"
    }
    if (-not (Test-Path -LiteralPath $librariesSource)) {
        throw "Missing Forge/Minecraft libraries folder: $librariesSource"
    }

    $minecraftConfig = Get-PropertyValue -Object $Config -Name 'minecraft' -Default ([pscustomobject]@{})
    $requireAssets = Test-ConfigFlag -Object $minecraftConfig -Name 'requireAssets' -Default $false
    if ($requireAssets -and -not (Test-Path -LiteralPath $assetsSource)) {
        throw "Config requires assets, but this folder is missing: $assetsSource"
    }

    $modsSource = Join-Path $payload 'mods'
    if (-not (Test-Path -LiteralPath $modsSource)) {
        throw "Missing mods folder: $modsSource"
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
        Write-Warning 'No mods are listed in config.json; all .jar files in payload\mods will be copied.'
    }

    Write-Host 'Payload validation passed.'
}

function Invoke-LocalMinecraftInstaller {
    param([string]$Root)

    $installerDir = Join-Path $Root 'payload\installers'
    if (-not (Test-Path -LiteralPath $installerDir)) {
        return $false
    }

    $msi = Get-ChildItem -LiteralPath $installerDir -Filter '*Minecraft*.msi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msi) {
        Invoke-External -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi.FullName, '/qn', '/norestart') -AllowedExitCodes @(0,3010)
        return $true
    }

    $exe = Get-ChildItem -LiteralPath $installerDir -Filter '*Minecraft*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) {
        return $false
    }

    $silentAttempts = @(
        @('/quiet','/norestart'),
        @('/silent','/norestart'),
        @('/S')
    )
    foreach ($args in $silentAttempts) {
        try {
            Invoke-External -FilePath $exe.FullName -ArgumentList $args -AllowedExitCodes @(0,3010)
            return $true
        } catch {
            Write-Warning "Installer attempt failed with args [$($args -join ' ')]: $($_.Exception.Message)"
        }
    }

    throw "Found $($exe.Name), but none of the common silent install attempts worked. Test the installer flags manually."
}

function Invoke-LocalConfiguredInstaller {
    param(
        [string]$InstallerDir,
        [string]$Name,
        [object[]]$Patterns,
        [object[]]$SilentArgSets
    )

    if (-not (Test-Path -LiteralPath $InstallerDir)) {
        return $false
    }

    $patternList = @($Patterns)
    if ($patternList.Count -eq 0) {
        $patternList = @('*.msi','*.exe')
    }

    $installer = $null
    foreach ($pattern in $patternList) {
        $installer = Get-ChildItem -LiteralPath $InstallerDir -Filter ([string]$pattern) -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($installer) { break }
    }

    if (-not $installer) {
        return $false
    }

    if ($installer.Extension -ieq '.msi') {
        Invoke-External -FilePath 'msiexec.exe' -ArgumentList @('/i', $installer.FullName, '/qn', '/norestart') -AllowedExitCodes @(0,3010)
        return $true
    }

    $argSets = @($SilentArgSets)
    if ($argSets.Count -eq 0) {
        $argSets = @(
            @('-install'),
            @('/quiet','/norestart'),
            @('/silent','/norestart'),
            @('/S'),
            @()
        )
    }

    foreach ($argSet in $argSets) {
        $args = @($argSet)
        try {
            Invoke-External -FilePath $installer.FullName -ArgumentList $args -AllowedExitCodes @(0,3010)
            return $true
        } catch {
            Write-Warning "$Name installer attempt failed with args [$($args -join ' ')]: $($_.Exception.Message)"
        }
    }

    throw "Found $($installer.Name), but none of the configured silent install attempts worked for $Name."
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

function Test-AppDetected {
    param([object]$App)

    $patterns = @((Get-PropertyValue -Object $App -Name 'detectRegistryNamePatterns' -Default @()))
    if ($patterns.Count -eq 0) { return $false }

    $installedNames = Get-InstalledProgramNames
    foreach ($pattern in $patterns) {
        foreach ($name in $installedNames) {
            if ($name -like [string]$pattern) {
                Write-Host "Detected installed app: $name"
                return $true
            }
        }
    }
    return $false
}

function Install-MinecraftLauncher {
    param(
        [string]$Root,
        [object]$Config
    )

    if ($SkipLauncherInstall) {
        Write-Host 'Skipping Minecraft Launcher install because -SkipLauncherInstall was used.'
        return
    }

    Write-Step 'Installing Minecraft Launcher'

    $launcherConfig = Get-PropertyValue -Object $Config -Name 'launcher' -Default ([pscustomobject]@{})
    $preferOffline = Test-ConfigFlag -Object $launcherConfig -Name 'preferOfflineInstaller' -Default $true
    $wingetId = [string](Get-PropertyValue -Object $launcherConfig -Name 'wingetId' -Default 'Mojang.MinecraftLauncher')

    if ($preferOffline) {
        if (Invoke-LocalMinecraftInstaller -Root $Root) { return }
        Write-Warning 'No local Minecraft installer was found. Falling back to WinGet.'
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            Invoke-External -FilePath $winget.Source -ArgumentList @(
                'install',
                '--id', $wingetId,
                '--exact',
                '--silent',
                '--accept-package-agreements',
                '--accept-source-agreements'
            ) -AllowedExitCodes @(0)
            return
        } catch {
            Write-Warning "WinGet install failed: $($_.Exception.Message)"
        }
    } else {
        Write-Warning 'winget.exe was not found.'
    }

    if (-not $preferOffline) {
        if (Invoke-LocalMinecraftInstaller -Root $Root) { return }
    }

    throw "Minecraft Launcher was not installed. Add a tested offline installer under payload\installers or make WinGet available."
}

function Install-ExtraApps {
    param(
        [string]$Root,
        [object]$Config
    )

    $apps = Get-PropertyValue -Object $Config -Name 'extraApps' -Default @()
    foreach ($app in @($apps)) {
        $enabled = Test-ConfigFlag -Object $app -Name 'enabled' -Default $false
        if (-not $enabled) { continue }

        $name = [string](Get-PropertyValue -Object $app -Name 'name' -Default 'Extra app')
        Write-Step "Installing $name"

        if (Test-AppDetected -App $app) {
            Write-Host "$name already appears to be installed. Skipping."
            continue
        }

        $installerFolder = [string](Get-PropertyValue -Object $app -Name 'installerFolder' -Default '')
        $installerDir = if ([string]::IsNullOrWhiteSpace($installerFolder)) {
            Join-Path $Root 'payload\installers'
        } else {
            Join-Path $Root $installerFolder
        }

        $patterns = @((Get-PropertyValue -Object $app -Name 'installerPatterns' -Default @()))
        $silentArgSets = @((Get-PropertyValue -Object $app -Name 'silentArgs' -Default @()))
        $preferOffline = Test-ConfigFlag -Object $app -Name 'preferOfflineInstaller' -Default $true
        $wingetId = [string](Get-PropertyValue -Object $app -Name 'wingetId' -Default '')

        if ($preferOffline) {
            if (Invoke-LocalConfiguredInstaller -InstallerDir $installerDir -Name $name -Patterns $patterns -SilentArgSets $silentArgSets) {
                continue
            }
            Write-Warning "No local installer was found for $name in $installerDir."
        }

        if (-not [string]::IsNullOrWhiteSpace($wingetId)) {
            $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
            if ($winget) {
                try {
                    Invoke-External -FilePath $winget.Source -ArgumentList @(
                        'install',
                        '--id', $wingetId,
                        '--exact',
                        '--silent',
                        '--accept-package-agreements',
                        '--accept-source-agreements'
                    ) -AllowedExitCodes @(0)
                    continue
                } catch {
                    Write-Warning "WinGet install failed for $name`: $($_.Exception.Message)"
                }
            } else {
                Write-Warning "winget.exe was not found while installing $name."
            }
        }

        if (-not $preferOffline) {
            if (Invoke-LocalConfiguredInstaller -InstallerDir $installerDir -Name $name -Patterns $patterns -SilentArgSets $silentArgSets) {
                continue
            }
        }

        throw "$name was not installed. Add a tested offline installer or verify its wingetId in payload\config.json."
    }
}

function Register-UserPhaseAtLogon {
    param(
        [string]$InstalledRoot,
        [object]$Config
    )

    if ($SkipRegisterUserSetup) {
        Write-Host 'Skipping user-phase registration because -SkipRegisterUserSetup was used.'
        return
    }

    Write-Step 'Registering per-user Minecraft setup at logon'
    $script = Join-Path $InstalledRoot 'Install-Minecraft189.ps1'
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode User -PackageRoot `"$InstalledRoot`""

    $setupVersion = [string](Get-PropertyValue -Object $Config -Name 'setupVersion' -Default '1')
    $activeSetupVersion = $setupVersion.Replace('.', ',')
    if ($activeSetupVersion -notmatch ',') {
        $activeSetupVersion = "$activeSetupVersion,0"
    }

    $activeSetupKey = 'HKLM:\Software\Microsoft\Active Setup\Installed Components\MinecraftModpackUserSetup'
    New-Item -Path $activeSetupKey -Force | Out-Null
    New-ItemProperty -Path $activeSetupKey -Name 'Version' -Value $activeSetupVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $activeSetupKey -Name 'StubPath' -Value $cmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $activeSetupKey -Name 'IsInstalled' -Value 1 -PropertyType DWord -Force | Out-Null

    $runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $runKey -Name 'Minecraft189UserSetup' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name 'MinecraftModpackUserSetup' -Force -ErrorAction SilentlyContinue

    $targetUsers = Get-TargetUsers -Config $Config
    if ($targetUsers.Count -gt 0) {
        Write-Host "User phase will run only for: $($targetUsers -join ', ')"
    } else {
        Write-Host 'User phase will run once for each interactive user through Active Setup.'
    }
}

function Install-MachinePhase {
    param(
        [string]$Root,
        [object]$Config,
        [string]$VersionId
    )

    if (-not (Test-IsAdmin)) {
        throw 'Machine setup must be run as Administrator. Right-click Run-Setup.cmd and choose Run as administrator.'
    }

    Validate-Payload -Root $Root -Config $Config -VersionId $VersionId

    $installedRoot = 'C:\ProgramData\MinecraftModpackSetup'
    $logDir = Join-Path $installedRoot 'Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    Write-Step 'Copying setup package to ProgramData'
    New-Item -ItemType Directory -Force -Path $installedRoot | Out-Null

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $resolvedInstalledRoot = $installedRoot.TrimEnd('\')
    if ($resolvedRoot -ieq $resolvedInstalledRoot) {
        Write-Host 'Setup package is already running from ProgramData.'
    } else {
        Copy-Item -LiteralPath (Join-Path $Root 'Install-Minecraft189.ps1') -Destination $installedRoot -Force
        if (Test-Path -LiteralPath (Join-Path $Root 'OOBE-Apply.ps1')) {
            Copy-Item -LiteralPath (Join-Path $Root 'OOBE-Apply.ps1') -Destination $installedRoot -Force
        }

        $installedPayload = Join-Path $installedRoot 'payload'
        if (Test-Path -LiteralPath $installedPayload) {
            Remove-Item -LiteralPath $installedPayload -Recurse -Force
        }
        Copy-Item -LiteralPath (Join-Path $Root 'payload') -Destination $installedRoot -Recurse -Force
    }

    Install-MinecraftLauncher -Root $installedRoot -Config $Config
    Install-ExtraApps -Root $installedRoot -Config $Config
    Register-UserPhaseAtLogon -InstalledRoot $installedRoot -Config $Config

    Write-Host 'Machine phase complete.'
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
            Write-Warning "launcher_profiles.json was unreadable. Backed it up to $backup and recreated it."
            $json = [pscustomobject]@{}
        }
    } else {
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

function Get-CompletionMarkerPath {
    param([string]$MinecraftDir)
    return (Join-Path $MinecraftDir '.minecraft-modpack-setup.json')
}

function Test-UserPhaseComplete {
    param(
        [string]$MinecraftDir,
        [string]$Version
    )

    $marker = Get-CompletionMarkerPath -MinecraftDir $MinecraftDir
    if (-not (Test-Path -LiteralPath $marker)) { return $false }

    try {
        $data = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        return ([string](Get-PropertyValue -Object $data -Name 'setupVersion' -Default '') -eq $Version)
    } catch {
        return $false
    }
}

function Create-CompletionMarker {
    param(
        [string]$MinecraftDir,
        [string]$Version,
        [string]$ForgeId
    )

    $marker = Get-CompletionMarkerPath -MinecraftDir $MinecraftDir
    [pscustomobject]@{
        status = 'complete'
        setupVersion = $Version
        computer = $env:COMPUTERNAME
        user = $env:USERNAME
        completedAt = (Get-Date -Format o)
        forgeVersionId = $ForgeId
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $marker -Encoding UTF8
}

function Get-TargetUsers {
    param([object]$Config)

    $windowsConfig = Get-PropertyValue -Object $Config -Name 'windows' -Default ([pscustomobject]@{})
    $targetUsers = @()
    $configuredTargets = Get-PropertyValue -Object $windowsConfig -Name 'targetUserSetupAccounts' -Default @()
    if ($configuredTargets) {
        $targetUsers += @($configuredTargets)
    }

    $player = [string](Get-PropertyValue -Object $windowsConfig -Name 'playerUserName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($player)) {
        $targetUsers += $player
    }

    return @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Test-ShouldRunForCurrentUser {
    param([object]$Config)

    $targetUsers = Get-TargetUsers -Config $Config
    if ($targetUsers.Count -eq 0) { return $true }
    return ($targetUsers -contains $env:USERNAME)
}

function Remove-UserPhaseLogonHookIfDone {
    param([object]$Config)

    if (-not (Test-IsAdmin)) { return }
    $runKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $runKey -Name 'Minecraft189UserSetup' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $runKey -Name 'MinecraftModpackUserSetup' -Force -ErrorAction SilentlyContinue
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
        }
        return
    }

    $jarFiles = @(Get-ChildItem -LiteralPath $ModsSource -Filter '*.jar' -File -ErrorAction Stop)
    foreach ($jar in $jarFiles) {
        Copy-Item -LiteralPath $jar.FullName -Destination $ModsDestination -Force
    }
}

function Install-UserPhase {
    param(
        [string]$Root,
        [object]$Config,
        [string]$VersionId,
        [string]$Name,
        [string]$Args,
        [string]$Version
    )

    if (Test-IsSystemContext) {
        throw 'User phase is running as SYSTEM, but it must run as the actual Windows user so %APPDATA% points to that user profile.'
    }

    if (-not (Test-ShouldRunForCurrentUser -Config $Config)) {
        Write-Host "Skipping user phase for $env:USERNAME because config targets another user."
        return
    }

    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'Could not resolve the current user APPDATA folder.'
    }

    $minecraftDir = Join-Path $appData '.minecraft'
    if (Test-UserPhaseComplete -MinecraftDir $minecraftDir -Version $Version) {
        Write-Host "User phase already completed for $env:USERNAME at setup version $Version."
        Remove-UserPhaseLogonHookIfDone -Config $Config
        return
    }

    Validate-Payload -Root $Root -Config $Config -VersionId $VersionId

    Write-Step "Configuring Minecraft for user $env:USERNAME"
    New-Item -ItemType Directory -Force -Path $minecraftDir | Out-Null

    $payload = Join-Path $Root 'payload'
    $modsSource = Join-Path $payload 'mods'
    $forgeTemplate = Join-Path $payload 'forge-template'
    $versionsSource = Join-Path $forgeTemplate 'versions'
    $librariesSource = Join-Path $forgeTemplate 'libraries'
    $assetsSource = Join-Path $forgeTemplate 'assets'

    Write-Step 'Copying Forge version and libraries'
    Copy-DirectoryContents -Source $versionsSource -Destination (Join-Path $minecraftDir 'versions')
    Copy-DirectoryContents -Source $librariesSource -Destination (Join-Path $minecraftDir 'libraries')

    $minecraftConfig = Get-PropertyValue -Object $Config -Name 'minecraft' -Default ([pscustomobject]@{})
    $copyAssets = Test-ConfigFlag -Object $minecraftConfig -Name 'copyAssets' -Default $true
    if ($copyAssets) {
        if (Test-Path -LiteralPath $assetsSource) {
            Write-Step 'Copying Minecraft assets'
            Copy-DirectoryContents -Source $assetsSource -Destination (Join-Path $minecraftDir 'assets')
        } else {
            Write-Warning "Assets folder not found at $assetsSource. The Launcher may need internet access on first run."
        }
    }

    Write-Step 'Copying mods'
    Copy-Mods -ModsSource $modsSource -ModsDestination (Join-Path $minecraftDir 'mods') -Config $Config

    Write-Step 'Creating Minecraft Launcher profile'
    Ensure-LauncherProfile -MinecraftDir $minecraftDir -VersionId $VersionId -Name $Name -Args $Args

    Create-CompletionMarker -MinecraftDir $minecraftDir -Version $Version -ForgeId $VersionId
    Remove-UserPhaseLogonHookIfDone -Config $Config
    Write-Host "User phase complete for $env:USERNAME."
}

# Main
$root = Get-ScriptRoot
$config = Read-SetupConfig -Root $root

$minecraftConfig = Get-PropertyValue -Object $config -Name 'minecraft' -Default ([pscustomobject]@{})
$resolvedProfileName = if ([string]::IsNullOrWhiteSpace($ProfileName)) { [string](Get-PropertyValue -Object $minecraftConfig -Name 'profileName' -Default 'Forge Modpack') } else { $ProfileName }
$resolvedForgeVersionId = if ([string]::IsNullOrWhiteSpace($ForgeVersionId)) { [string](Get-PropertyValue -Object $minecraftConfig -Name 'versionId' -Default '1.8.9-forge1.8.9-11.15.1.2318-1.8.9') } else { $ForgeVersionId }
$resolvedJavaArgs = if ([string]::IsNullOrWhiteSpace($JavaArgs)) { [string](Get-PropertyValue -Object $minecraftConfig -Name 'javaArgs' -Default '-Xmx2G -Xms1G') } else { $JavaArgs }
$resolvedSetupVersion = if ([string]::IsNullOrWhiteSpace($SetupVersion)) { [string](Get-PropertyValue -Object $config -Name 'setupVersion' -Default '1') } else { $SetupVersion }

$installedRoot = 'C:\ProgramData\MinecraftModpackSetup'
$legacyInstalledRoot = 'C:\ProgramData\Minecraft189Setup'
$logRoot = if (Test-Path -LiteralPath $installedRoot) { Join-Path $installedRoot 'Logs' } elseif (Test-Path -LiteralPath $legacyInstalledRoot) { Join-Path $legacyInstalledRoot 'Logs' } else { Join-Path $root 'logs' }
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("Install-MinecraftModpack-$env:COMPUTERNAME-$env:USERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Mode requested: $Mode"
    Write-Host "Script/package root: $root"
    Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Setup version: $resolvedSetupVersion"
    Write-Host "Minecraft profile: $resolvedProfileName"
    Write-Host "Minecraft version id: $resolvedForgeVersionId"

    $effectiveMode = $Mode
    if ($Mode -eq 'Auto') {
        if (Test-IsSystemContext) {
            $effectiveMode = 'Machine'
        } else {
            $effectiveMode = 'MachineThenUser'
        }
    }

    switch ($effectiveMode) {
        'Machine' {
            Install-MachinePhase -Root $root -Config $config -VersionId $resolvedForgeVersionId
        }
        'User' {
            Install-UserPhase -Root $root -Config $config -VersionId $resolvedForgeVersionId -Name $resolvedProfileName -Args $resolvedJavaArgs -Version $resolvedSetupVersion
        }
        'MachineThenUser' {
            Install-MachinePhase -Root $root -Config $config -VersionId $resolvedForgeVersionId
            Install-UserPhase -Root $installedRoot -Config $config -VersionId $resolvedForgeVersionId -Name $resolvedProfileName -Args $resolvedJavaArgs -Version $resolvedSetupVersion
        }
        default {
            throw "Unknown effective mode: $effectiveMode"
        }
    }

    Write-Host "`nSUCCESS. Log saved to $logPath" -ForegroundColor Green
}
catch {
    Write-Error $_
    Write-Host "`nFAILED. Log saved to $logPath" -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
