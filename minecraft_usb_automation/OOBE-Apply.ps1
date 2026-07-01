<#
OOBE entry point for reset laptops.

This script is intended to be launched by a provisioning package during OOBE.
It creates local accounts using script commands, which is the most portable path
when many devices may be Windows Home, then runs the machine phase of the
Minecraft modpack installer.

Do not commit real passwords. Put them in payload\local-secrets.psd1 on the USB.
#>

[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$ConfigPath = '',
    [switch]$SkipMinecraftSetup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
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

function Read-LocalSecrets {
    param([string]$Root)

    $path = Join-Path $Root 'payload\local-secrets.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing local secrets file: $path. Copy payload\local-secrets.example.psd1 to local-secrets.psd1 on the USB and fill it in."
    }

    return (Import-PowerShellDataFile -Path $path)
}

function New-Password {
    param([string]$PlainText)

    if ([string]::IsNullOrWhiteSpace($PlainText)) {
        return $null
    }
    return (ConvertTo-SecureString $PlainText -AsPlainText -Force)
}

function Test-LocalUserExists {
    param([string]$Name)

    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        return ($null -ne (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue))
    }

    $result = & net.exe user $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Get-LocalGroupNameBySid {
    param([string]$Sid)

    try {
        $sidObject = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $sidObject.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    } catch {
        if ($Sid -eq 'S-1-5-32-544') { return 'Administrators' }
        if ($Sid -eq 'S-1-5-32-545') { return 'Users' }
        throw
    }
}

function Ensure-LocalUser {
    param(
        [string]$Name,
        [string]$Password,
        [string]$FullName,
        [string]$Description,
        [bool]$IsAdmin
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Cannot create a local user with an empty name.'
    }

    $exists = Test-LocalUserExists -Name $Name
    $securePassword = New-Password -PlainText $Password

    if (Get-Command New-LocalUser -ErrorAction SilentlyContinue) {
        if (-not $exists) {
            $args = @{
                Name = $Name
                FullName = $FullName
                Description = $Description
                AccountNeverExpires = $true
            }
            if ($securePassword) {
                $args['Password'] = $securePassword
            } else {
                $args['NoPassword'] = $true
            }
            New-LocalUser @args | Out-Null
        } elseif ($securePassword) {
            Set-LocalUser -Name $Name -Password $securePassword
        }

        $adminGroup = Get-LocalGroupNameBySid -Sid 'S-1-5-32-544'
        $usersGroup = Get-LocalGroupNameBySid -Sid 'S-1-5-32-545'

        if ($IsAdmin) {
            Add-LocalGroupMember -Group $adminGroup -Member $Name -ErrorAction SilentlyContinue
        } else {
            Add-LocalGroupMember -Group $usersGroup -Member $Name -ErrorAction SilentlyContinue
            Remove-LocalGroupMember -Group $adminGroup -Member $Name -ErrorAction SilentlyContinue
        }
        return
    }

    if (-not $exists) {
        if ([string]::IsNullOrWhiteSpace($Password)) {
            & net.exe user $Name /add /active:yes
        } else {
            & net.exe user $Name $Password /add /active:yes
        }
        if ($LASTEXITCODE -ne 0) {
            throw "net user failed while creating $Name with exit code $LASTEXITCODE"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Password)) {
        & net.exe user $Name $Password
        if ($LASTEXITCODE -ne 0) {
            throw "net user failed while updating $Name with exit code $LASTEXITCODE"
        }
    }

    $adminNetGroup = Get-LocalGroupNameBySid -Sid 'S-1-5-32-544'
    $usersNetGroup = Get-LocalGroupNameBySid -Sid 'S-1-5-32-545'

    if ($IsAdmin) {
        & net.exe localgroup $adminNetGroup $Name /add | Out-Null
    } else {
        & net.exe localgroup $usersNetGroup $Name /add | Out-Null
        & net.exe localgroup $adminNetGroup $Name /delete | Out-Null
    }
}

function Ensure-Accounts {
    param(
        [object]$Config,
        [hashtable]$Secrets
    )

    $windowsConfig = Get-PropertyValue -Object $Config -Name 'windows' -Default ([pscustomobject]@{})
    $adminUser = [string](Get-PropertyValue -Object $windowsConfig -Name 'adminUserName' -Default 'SetupAdmin')
    $playerUser = [string](Get-PropertyValue -Object $windowsConfig -Name 'playerUserName' -Default 'Player')

    $adminPassword = [string]$Secrets['AdminPassword']
    $playerPassword = [string]$Secrets['PlayerPassword']

    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        throw 'AdminPassword is required in payload\local-secrets.psd1.'
    }

    Write-Step "Ensuring local admin account: $adminUser"
    Ensure-LocalUser -Name $adminUser -Password $adminPassword -FullName 'Setup Administrator' -Description 'Local administrator for laptop setup and maintenance.' -IsAdmin $true

    Write-Step "Ensuring standard player account: $playerUser"
    Ensure-LocalUser -Name $playerUser -Password $playerPassword -FullName 'Player' -Description 'Standard account for children playing Minecraft.' -IsAdmin $false
}

$root = Get-ScriptRoot
$logRoot = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("OOBE-Apply-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Package root: $root"
    Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

    $config = Read-JsonConfig -Root $root
    $secrets = Read-LocalSecrets -Root $root

    Ensure-Accounts -Config $config -Secrets $secrets

    if (-not $SkipMinecraftSetup) {
        $installer = Join-Path $root 'Install-Minecraft189.ps1'
        if (-not (Test-Path -LiteralPath $installer)) {
            throw "Missing installer script: $installer"
        }

        Write-Step 'Running machine modpack setup'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Mode Machine -PackageRoot $root
        if ($LASTEXITCODE -ne 0) {
            throw "Install-Minecraft189.ps1 failed with exit code $LASTEXITCODE"
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
