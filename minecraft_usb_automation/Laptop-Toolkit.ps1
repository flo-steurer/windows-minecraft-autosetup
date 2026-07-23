<#
Menu-driven setup toolkit for existing Windows installations.

Run this script as the Windows user who will play Minecraft. The cleanup action
requests Administrator permission separately; Minecraft files remain associated
with the original user's profile.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Cleanup', 'MinecraftPack', 'RobloxStudio')]
    [string]$Action = 'Menu',

    [string]$PackId = '',

    [string]$PackageRoot = '',

    [string]$ConfigPath = '',

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
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

function Get-ToolkitRoot {
    if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
        return (Resolve-Path -LiteralPath $PackageRoot).Path
    }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Read-JsonFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing $Description`: $Path"
    }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        throw "Could not parse $Description $Path`: $($_.Exception.Message)"
    }
}

function Read-ToolkitConfig {
    param([string]$Root)

    $path = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $Root 'payload\config.json'
    }
    return (Read-JsonFile -Path $path -Description 'toolkit config')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedCleanup {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Cannot determine the toolkit script path for elevation.'
    }

    Write-Host 'Windows will now request Administrator permission for cleanup.'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-Action', 'Cleanup',
        '-PackageRoot', "`"$Root`"",
        '-Force'
    )
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Elevated cleanup failed or was cancelled (exit code $($process.ExitCode))."
    }
}

function Get-SystemDriveFreeBytes {
    try {
        $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop
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

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

    Write-Host "Cleaning $Label`: $Path"
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not remove $($item.FullName): $($_.Exception.Message)"
        }
    }
}

function Stop-ServiceForCleanup {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -eq 'Stopped') { return $false }
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "Could not stop service $Name`: $($_.Exception.Message)"
        return $false
    }
}

function Restart-ServiceAfterCleanup {
    param(
        [string]$Name,
        [bool]$WasRunning
    )

    if (-not $WasRunning) { return }
    try {
        Start-Service -Name $Name -ErrorAction Stop
    } catch {
        Write-Warning "Could not restart service $Name`: $($_.Exception.Message)"
    }
}

function Invoke-Cleanup {
    param([object]$Config)

    if (-not (Test-IsAdministrator)) {
        throw 'Cleanup must run with Administrator permission.'
    }

    $cleanup = Get-PropertyValue -Object $Config -Name 'cleanup' -Default ([pscustomobject]@{})
    Write-Step 'Cleaning disposable Windows files'
    $before = Get-SystemDriveFreeBytes
    Write-Host "Free space before cleanup: $(Format-Bytes -Bytes $before)"

    if (Test-ConfigFlag -Object $cleanup -Name 'clearWindowsTemp' -Default $true) {
        Remove-DirectoryContents -Path (Join-Path $env:WINDIR 'Temp') -Label 'Windows temporary files'
    }
    if (Test-ConfigFlag -Object $cleanup -Name 'clearAllUserTemp' -Default $true) {
        foreach ($userDir in @(Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
            Remove-DirectoryContents -Path (Join-Path $userDir.FullName 'AppData\Local\Temp') -Label "$($userDir.Name) temporary files"
        }
    }
    if (Test-ConfigFlag -Object $cleanup -Name 'emptyRecycleBin' -Default $true) {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Host 'Emptied the recycle bin.'
        } catch {
            Write-Warning "Could not empty the recycle bin: $($_.Exception.Message)"
        }
    }
    if (Test-ConfigFlag -Object $cleanup -Name 'clearWindowsUpdateDownloadCache' -Default $true) {
        $updateWasRunning = Stop-ServiceForCleanup -Name 'wuauserv'
        $bitsWasRunning = Stop-ServiceForCleanup -Name 'bits'
        Remove-DirectoryContents -Path (Join-Path $env:WINDIR 'SoftwareDistribution\Download') -Label 'Windows Update download cache'
        Restart-ServiceAfterCleanup -Name 'bits' -WasRunning $bitsWasRunning
        Restart-ServiceAfterCleanup -Name 'wuauserv' -WasRunning $updateWasRunning
    }
    if (Test-ConfigFlag -Object $cleanup -Name 'clearDeliveryOptimizationCache' -Default $true) {
        $deliveryWasRunning = Stop-ServiceForCleanup -Name 'DoSvc'
        Remove-DirectoryContents -Path 'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache' -Label 'Delivery Optimization cache'
        Restart-ServiceAfterCleanup -Name 'DoSvc' -WasRunning $deliveryWasRunning
    }
    if (Test-ConfigFlag -Object $cleanup -Name 'runComponentCleanup' -Default $false) {
        Write-Host 'Running optional Windows component cleanup. This can take several minutes.'
        $process = Start-Process -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            Write-Warning "Windows component cleanup exited with code $($process.ExitCode)."
        }
    }

    $after = Get-SystemDriveFreeBytes
    Write-Host "Free space after cleanup: $(Format-Bytes -Bytes $after)"
    if ($before -ge 0 -and $after -ge 0) {
        Write-Host "Space recovered: $(Format-Bytes -Bytes ($after - $before))"
    }
    Write-Success 'Cleanup complete. Personal documents and installed applications were not removed.'
}

function Invoke-ExternalInstaller {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int[]]$AllowedExitCodes = @(0, 3010),
        [bool]$Elevate = $false
    )

    Write-Host "Running installer: $([IO.Path]::GetFileName($FilePath)) $($ArgumentList -join ' ')"
    $startArguments = @{
        FilePath = $FilePath
        Wait = $true
        PassThru = $true
    }
    if (@($ArgumentList).Count -gt 0) {
        $startArguments['ArgumentList'] = $ArgumentList
    }
    if ($Elevate -and -not (Test-IsAdministrator)) {
        Write-Host 'Windows will request Administrator permission for this installer.'
        $startArguments['Verb'] = 'RunAs'
    }
    $process = Start-Process @startArguments
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Installer exited with code $($process.ExitCode): $FilePath"
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
        foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
            $displayName = [string](Get-PropertyValue -Object $item -Name 'DisplayName' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                $names += $displayName
            }
        }
    }
    return @($names | Select-Object -Unique)
}

function Test-Java8Runtime {
    $java = Get-Command 'java.exe' -ErrorAction SilentlyContinue
    if ($java) {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $versionOutput = & $java.Source -version 2>&1
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        $versionText = ($versionOutput | ForEach-Object { $_.ToString() } | Out-String).Trim()
        if ($versionText -match 'version "1\.8\.' -or $versionText -match 'version "8') {
            Write-Host "Detected Java 8 on PATH: $($java.Source)"
            return $true
        }
    }

    $commonRoots = @(
        "$env:ProgramFiles\Java",
        "${env:ProgramFiles(x86)}\Java",
        "$env:ProgramFiles\Eclipse Adoptium",
        "${env:ProgramFiles(x86)}\Eclipse Adoptium"
    )
    foreach ($commonRoot in $commonRoots) {
        if ([string]::IsNullOrWhiteSpace($commonRoot) -or -not (Test-Path -LiteralPath $commonRoot -PathType Container)) {
            continue
        }
        $runtime = Get-ChildItem -LiteralPath $commonRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(^|[^0-9])1?\.?8([^0-9]|$)' -or $_.Name -like '*8u*' } |
            Select-Object -First 1
        if ($runtime) {
            Write-Host "Detected a Java 8 runtime: $($runtime.FullName)"
            return $true
        }
    }
    return $false
}

function Test-ConfiguredAppInstalled {
    param([object]$App)

    $name = [string](Get-PropertyValue -Object $App -Name 'name' -Default 'Application')
    if ((Test-ConfigFlag -Object $App -Name 'detectJava8' -Default $false) -and (Test-Java8Runtime)) {
        return $true
    }

    $registryPatterns = @((Get-PropertyValue -Object $App -Name 'detectRegistryNamePatterns' -Default @()))
    $installedNames = Get-InstalledProgramNames
    foreach ($pattern in $registryPatterns) {
        foreach ($installedName in $installedNames) {
            if ($installedName -like [string]$pattern) {
                Write-Host "Detected $name`: $installedName"
                return $true
            }
        }
    }

    $startAppPatterns = @((Get-PropertyValue -Object $App -Name 'detectStartAppPatterns' -Default @()))
    if ($startAppPatterns.Count -gt 0 -and (Get-Command Get-StartApps -ErrorAction SilentlyContinue)) {
        $startApps = @(Get-StartApps)
        foreach ($pattern in $startAppPatterns) {
            $match = $startApps | Where-Object { $_.Name -like [string]$pattern } | Select-Object -First 1
            if ($match) {
                Write-Host "Detected $name in the Start menu: $($match.Name)"
                return $true
            }
        }
    }
    return $false
}

function Find-LocalInstaller {
    param(
        [string]$Root,
        [object]$App
    )

    $folder = [string](Get-PropertyValue -Object $App -Name 'installerFolder' -Default '')
    if ([string]::IsNullOrWhiteSpace($folder)) { return $null }
    $installerDir = Join-Path $Root $folder
    if (-not (Test-Path -LiteralPath $installerDir -PathType Container)) { return $null }

    $patterns = @((Get-PropertyValue -Object $App -Name 'installerPatterns' -Default @('*.msi', '*.exe')))
    foreach ($pattern in $patterns) {
        $installer = Get-ChildItem -LiteralPath $installerDir -Filter ([string]$pattern) -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($installer) { return $installer }
    }
    return $null
}

function Invoke-LocalInstaller {
    param(
        [object]$Installer,
        [object]$App
    )

    $requiresElevation = Test-ConfigFlag -Object $App -Name 'requiresElevation' -Default $false
    if ($Installer.Extension -ieq '.msi') {
        Invoke-ExternalInstaller -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$($Installer.FullName)`"", '/qn', '/norestart') -Elevate $requiresElevation
        return
    }

    $argSets = @((Get-PropertyValue -Object $App -Name 'silentArgs' -Default @(@())))
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($argSet in $argSets) {
        $arguments = @($argSet | ForEach-Object { [string]$_ })
        try {
            Invoke-ExternalInstaller -FilePath $Installer.FullName -ArgumentList $arguments -Elevate $requiresElevation
            return
        } catch {
            $failures.Add($_.Exception.Message) | Out-Null
            Write-Warning "Installer attempt failed with arguments [$($arguments -join ' ')]."
        }
    }
    if (Test-ConfigFlag -Object $App -Name 'allowInteractiveInstaller' -Default $false) {
        Write-Host 'Silent installation was unsuccessful. Starting the installer interactively.'
        Invoke-ExternalInstaller -FilePath $Installer.FullName -ArgumentList @() -Elevate $requiresElevation
        return
    }
    throw "The local installer $($Installer.Name) failed. Attempts: $($failures -join '; ')"
}

function Invoke-WinGetInstall {
    param([object]$App)

    $wingetId = [string](Get-PropertyValue -Object $App -Name 'wingetId' -Default '')
    if ([string]::IsNullOrWhiteSpace($wingetId)) { return $false }

    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Warning 'WinGet is not available on this Windows installation.'
        return $false
    }

    try {
        Invoke-ExternalInstaller -FilePath $winget.Source -ArgumentList @(
            'install',
            '--id', $wingetId,
            '--exact',
            '--silent',
            '--accept-package-agreements',
            '--accept-source-agreements'
        ) -AllowedExitCodes @(0)
        return $true
    } catch {
        Write-Warning "WinGet could not install $wingetId`: $($_.Exception.Message)"
        return $false
    }
}

function Install-ConfiguredApp {
    param(
        [string]$Root,
        [object]$App
    )

    $name = [string](Get-PropertyValue -Object $App -Name 'name' -Default 'Application')
    Write-Step "Checking $name"
    if (Test-ConfiguredAppInstalled -App $App) {
        Write-Host "$name is already installed."
        return
    }

    $preferOffline = Test-ConfigFlag -Object $App -Name 'preferOfflineInstaller' -Default $true
    $localInstaller = Find-LocalInstaller -Root $Root -App $App
    if ($preferOffline -and $localInstaller) {
        try {
            Invoke-LocalInstaller -Installer $localInstaller -App $App
            Write-Success "$name installation finished."
            return
        } catch {
            if (Test-ConfiguredAppInstalled -App $App) {
                Write-Success "$name now appears to be installed."
                return
            }
            Write-Warning "The offline $name installer failed: $($_.Exception.Message)"
        }
    }
    if ($preferOffline -and -not $localInstaller) {
        Write-Warning "No matching offline installer was found for $name."
    }

    if (Invoke-WinGetInstall -App $App) {
        Write-Success "$name installation finished."
        return
    }

    if (-not $preferOffline -and $localInstaller) {
        Invoke-LocalInstaller -Installer $localInstaller -App $App
        Write-Success "$name installation finished."
        return
    }

    $folder = [string](Get-PropertyValue -Object $App -Name 'installerFolder' -Default 'payload\installers')
    $wingetId = [string](Get-PropertyValue -Object $App -Name 'wingetId' -Default '(not configured)')
    throw "$name could not be installed. Add a tested installer under $folder or verify WinGet package $wingetId."
}

function Get-AppConfig {
    param(
        [object]$Config,
        [string]$Id
    )

    $apps = Get-PropertyValue -Object $Config -Name 'apps' -Default ([pscustomobject]@{})
    $app = Get-PropertyValue -Object $apps -Name $Id -Default $null
    if ($null -eq $app) {
        throw "Application '$Id' is missing from payload\config.json."
    }
    return $app
}

function Get-MinecraftPacks {
    param([string]$Root)

    $packsRoot = Join-Path $Root 'payload\minecraft-packs'
    if (-not (Test-Path -LiteralPath $packsRoot -PathType Container)) { return @() }

    $packs = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $packsRoot -Directory -ErrorAction Stop | Sort-Object Name)) {
        $packConfigPath = Join-Path $directory.FullName 'pack.json'
        if (-not (Test-Path -LiteralPath $packConfigPath -PathType Leaf)) { continue }
        $config = Read-JsonFile -Path $packConfigPath -Description 'Minecraft pack config'
        if (-not (Test-ConfigFlag -Object $config -Name 'enabled' -Default $true)) { continue }
        $id = [string](Get-PropertyValue -Object $config -Name 'id' -Default $directory.Name)
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Minecraft pack in $($directory.FullName) has an empty id."
        }
        $name = [string](Get-PropertyValue -Object $config -Name 'name' -Default $id)
        $packs += [pscustomobject]@{
            Id = $id
            Name = $name
            Root = $directory.FullName
            Config = $config
        }
    }
    $duplicate = $packs | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | Select-Object -First 1
    if ($duplicate) {
        throw "Multiple enabled Minecraft packs use id '$($duplicate.Name)'. Every pack id must be unique."
    }
    return @($packs)
}

function Get-MinecraftPack {
    param(
        [string]$Root,
        [string]$Id
    )

    $packs = @(Get-MinecraftPacks -Root $Root)
    $pack = $packs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $pack) {
        $available = if ($packs.Count -gt 0) { ($packs.Id -join ', ') } else { '(none)' }
        throw "Minecraft pack '$Id' was not found. Available packs: $available"
    }
    return $pack
}

function Test-DirectoryHasFiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $payloadFile = Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' -and $_.Name -notlike '._*' } |
        Select-Object -First 1
    return ($null -ne $payloadFile)
}

function Get-PackMods {
    param([object]$Pack)

    $manifest = @((Get-PropertyValue -Object $Pack.Config -Name 'mods' -Default @()))
    $modsRoot = Join-Path $Pack.Root 'mods'
    if ($manifest.Count -eq 0) {
        return @(Get-ChildItem -LiteralPath $modsRoot -Filter '*.jar' -File -ErrorAction SilentlyContinue)
    }

    $files = @()
    foreach ($entry in $manifest) {
        $fileName = if ($entry -is [string]) {
            [string]$entry
        } else {
            [string](Get-PropertyValue -Object $entry -Name 'file' -Default '')
        }
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            throw "A mod entry in $($Pack.Id)\pack.json has no file name."
        }
        $path = Join-Path $modsRoot $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required mod is missing: $path"
        }

        if ($entry -isnot [string]) {
            $expectedHash = [string](Get-PropertyValue -Object $entry -Name 'sha256' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                if ($actualHash -ine $expectedHash) {
                    throw "SHA256 mismatch for $fileName. Expected $expectedHash but found $actualHash."
                }
            }
        }
        $files += Get-Item -LiteralPath $path
    }
    return @($files)
}

function Test-MinecraftPackPayload {
    param([object]$Pack)

    Write-Step "Validating $($Pack.Name)"
    $versionId = [string](Get-PropertyValue -Object $Pack.Config -Name 'versionId' -Default '')
    if ([string]::IsNullOrWhiteSpace($versionId)) {
        throw "Pack $($Pack.Id) has no versionId."
    }

    $versionPath = Join-Path (Join-Path $Pack.Root 'versions') $versionId
    if (-not (Test-DirectoryHasFiles -Path $versionPath)) {
        throw "Forge/Minecraft version payload is missing or empty: $versionPath"
    }
    $librariesPath = Join-Path $Pack.Root 'libraries'
    if (-not (Test-DirectoryHasFiles -Path $librariesPath)) {
        throw "Library payload is missing or empty: $librariesPath"
    }

    $mods = @(Get-PackMods -Pack $Pack)
    if ($mods.Count -eq 0) {
        throw "No mod .jar files were found for pack $($Pack.Id)."
    }

    $copyAssets = Test-ConfigFlag -Object $Pack.Config -Name 'copyAssets' -Default $true
    $requireAssets = Test-ConfigFlag -Object $Pack.Config -Name 'requireAssets' -Default $false
    $assetsPath = Join-Path $Pack.Root 'assets'
    if ($requireAssets -and -not (Test-DirectoryHasFiles -Path $assetsPath)) {
        throw "Pack $($Pack.Id) requires assets, but its assets folder is empty or missing."
    }
    if ($copyAssets -and -not (Test-DirectoryHasFiles -Path $assetsPath)) {
        Write-Warning 'No assets are bundled. Minecraft Launcher will need internet access to download them.'
    }
    Write-Host "Payload is complete: version $versionId, $($mods.Count) mods."
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Clear-ModsDirectory {
    param([string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            throw "Could not remove existing mod item $($item.FullName). Close Minecraft and try again. $($_.Exception.Message)"
        }
    }
    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop).Count -ne 0) {
        throw "The existing mods folder could not be emptied: $Path"
    }
    Write-Host "Removed all existing contents from: $Path"
}

function Ensure-LauncherProfile {
    param(
        [string]$MinecraftDir,
        [object]$Pack
    )

    $profilePath = Join-Path $MinecraftDir 'launcher_profiles.json'
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        } catch {
            $backup = "$profilePath.broken.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Copy-Item -LiteralPath $profilePath -Destination $backup -Force
            Write-Warning "The existing launcher profile file was unreadable. It was backed up to $backup."
            $json = [pscustomobject]@{}
        }
    } else {
        Write-Warning 'Minecraft Launcher has not created launcher_profiles.json yet. The toolkit will create it.'
        $json = [pscustomobject]@{}
    }

    if (-not $json.PSObject.Properties['profiles']) {
        Add-Member -InputObject $json -MemberType NoteProperty -Name 'profiles' -Value ([pscustomobject]@{})
    }

    $profileKey = [string](Get-PropertyValue -Object $Pack.Config -Name 'profileKey' -Default $Pack.Id)
    $profileName = [string](Get-PropertyValue -Object $Pack.Config -Name 'profileName' -Default $Pack.Name)
    $versionId = [string](Get-PropertyValue -Object $Pack.Config -Name 'versionId' -Default '')
    $javaArgs = [string](Get-PropertyValue -Object $Pack.Config -Name 'javaArgs' -Default '-Xmx2G -Xms1G')
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $profile = [pscustomobject]@{
        name = $profileName
        type = 'custom'
        created = $now
        lastUsed = $now
        lastVersionId = $versionId
        javaArgs = $javaArgs
    }

    if ($json.profiles.PSObject.Properties[$profileKey]) {
        $json.profiles.$profileKey = $profile
    } else {
        Add-Member -InputObject $json.profiles -MemberType NoteProperty -Name $profileKey -Value $profile
    }
    $json | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $profilePath -Encoding UTF8
    Write-Host "Created or updated Launcher profile: $profileName"
}

function Confirm-ModReplacement {
    param([object]$Pack)

    if ($Force) { return }
    Write-Host ''
    Write-Host 'IMPORTANT: This will permanently remove everything currently in:' -ForegroundColor Yellow
    Write-Host "  $([Environment]::GetFolderPath('ApplicationData'))\.minecraft\mods" -ForegroundColor Yellow
    Write-Host "It will then install only the mods from $($Pack.Name)." -ForegroundColor Yellow
    $answer = Read-Host 'Type INSTALL to continue'
    if ($answer -cne 'INSTALL') {
        throw 'Minecraft pack installation was cancelled. No mods were removed.'
    }
}

function Install-MinecraftPack {
    param(
        [string]$Root,
        [object]$Config,
        [object]$Pack
    )

    Test-MinecraftPackPayload -Pack $Pack
    Confirm-ModReplacement -Pack $Pack

    $launcher = Get-AppConfig -Config $Config -Id 'minecraftLauncher'
    $java = Get-AppConfig -Config $Config -Id 'java8'
    Install-ConfiguredApp -Root $Root -App $launcher
    Install-ConfiguredApp -Root $Root -App $java

    $launcherProcess = Get-Process -Name @('MinecraftLauncher', 'Minecraft') -ErrorAction SilentlyContinue
    if ($launcherProcess) {
        throw 'Minecraft Launcher is running. Close it completely, then run the pack installation again. No mods were removed.'
    }

    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'Could not resolve APPDATA for the current Windows user.'
    }
    $minecraftDir = Join-Path $appData '.minecraft'
    New-Item -ItemType Directory -Force -Path $minecraftDir | Out-Null

    Write-Step 'Installing Forge/Minecraft files'
    Copy-DirectoryContents -Source (Join-Path $Pack.Root 'versions') -Destination (Join-Path $minecraftDir 'versions')
    Copy-DirectoryContents -Source (Join-Path $Pack.Root 'libraries') -Destination (Join-Path $minecraftDir 'libraries')
    if (Test-ConfigFlag -Object $Pack.Config -Name 'copyAssets' -Default $true) {
        Copy-DirectoryContents -Source (Join-Path $Pack.Root 'assets') -Destination (Join-Path $minecraftDir 'assets')
    }

    Write-Step 'Replacing the mods folder'
    $modsDestination = Join-Path $minecraftDir 'mods'
    Clear-ModsDirectory -Path $modsDestination
    foreach ($mod in @(Get-PackMods -Pack $Pack)) {
        Copy-Item -LiteralPath $mod.FullName -Destination $modsDestination -Force
        Write-Host "Installed mod: $($mod.Name)"
    }

    Write-Step 'Updating Minecraft Launcher'
    Ensure-LauncherProfile -MinecraftDir $minecraftDir -Pack $Pack
    Write-Success "$($Pack.Name) is installed for Windows user $env:USERNAME."
    Write-Host "Minecraft folder: $minecraftDir"
}

function Install-RobloxStudio {
    param(
        [string]$Root,
        [object]$Config
    )

    $roblox = Get-AppConfig -Config $Config -Id 'robloxStudio'
    Install-ConfiguredApp -Root $Root -App $roblox
}

function Read-PackSelection {
    param([object[]]$Packs)

    if ($Packs.Count -eq 0) {
        throw 'No enabled Minecraft packs were found under payload\minecraft-packs.'
    }
    Write-Host ''
    for ($index = 0; $index -lt $Packs.Count; $index++) {
        Write-Host "$($index + 1). $($Packs[$index].Name)"
    }
    Write-Host '0. Back'
    $selection = Read-Host 'Select a Minecraft pack'
    $number = 0
    if (-not [int]::TryParse($selection, [ref]$number)) { return $null }
    if ($number -eq 0) { return $null }
    if ($number -lt 1 -or $number -gt $Packs.Count) {
        Write-Warning 'Invalid selection.'
        return $null
    }
    return $Packs[$number - 1]
}

function Show-Menu {
    param(
        [string]$Root,
        [object]$Config
    )

    while ($true) {
        Write-Host ''
        Write-Host 'EDUTAIN LAPTOP TOOLKIT' -ForegroundColor Cyan
        Write-Host "Current Windows user: $env:USERNAME"
        Write-Host ''
        Write-Host '1. Clean up disk space'
        Write-Host '2. Install a Minecraft pack'
        Write-Host '3. Install Roblox Studio'
        Write-Host '4. Exit'
        $selection = Read-Host 'Choose an option'

        try {
            switch ($selection) {
                '1' { Invoke-ElevatedCleanup -Root $Root }
                '2' {
                    $pack = Read-PackSelection -Packs @(Get-MinecraftPacks -Root $Root)
                    if ($pack) { Install-MinecraftPack -Root $Root -Config $Config -Pack $pack }
                }
                '3' { Install-RobloxStudio -Root $Root -Config $Config }
                '4' { return }
                default { Write-Warning 'Choose 1, 2, 3, or 4.' }
            }
        } catch {
            Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

$root = Get-ToolkitRoot
$logRoot = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("Laptop-Toolkit-$env:COMPUTERNAME-$env:USERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Start-Transcript -Path $logPath -Force | Out-Null
$exitCode = 0
try {
    Write-Host "Toolkit root: $root"
    Write-Host "Log: $logPath"
    $config = Read-ToolkitConfig -Root $root

    switch ($Action) {
        'Menu' { Show-Menu -Root $root -Config $config }
        'Cleanup' {
            if (-not (Test-IsAdministrator)) {
                Invoke-ElevatedCleanup -Root $root
            } else {
                Invoke-Cleanup -Config $config
            }
        }
        'MinecraftPack' {
            if ([string]::IsNullOrWhiteSpace($PackId)) {
                throw '-PackId is required with -Action MinecraftPack.'
            }
            $pack = Get-MinecraftPack -Root $root -Id $PackId
            Install-MinecraftPack -Root $root -Config $config -Pack $pack
        }
        'RobloxStudio' { Install-RobloxStudio -Root $root -Config $config }
    }
} catch {
    $exitCode = 1
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "See log: $logPath" -ForegroundColor Red
} finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
