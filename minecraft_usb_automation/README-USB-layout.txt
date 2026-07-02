Minecraft/Forge USB automation kit
==================================

Use this either after Windows Reset through OOBE provisioning, or on an existing
Windows install through the fast no-reset path.

Fast no-reset workflow
----------------------
Use this when Reset this PC is taking too long.

1. Log into an existing administrator account on the laptop.
2. Insert the USB stick.
3. Right-click Run-Reprovision-Existing.cmd and choose "Run as administrator".
4. Sign out.
5. Log in once as the configured player account.
6. Sign into Minecraft Launcher with a licensed Minecraft account and choose the configured Forge profile.

For the cleanest result, configure a player account name that does not already
exist on the laptop. A fresh Windows account gives you a fresh user profile
without waiting for a full OS reset.

This path also runs conservative disk cleanup: temp folders, recycle bin,
Windows Update download cache, and Delivery Optimization cache. It does not
delete documents, downloads, old profiles, or installed apps.

Aggressive cleanup can be enabled in payload\config.json, but it requires:

  "destructiveCleanup": {
    "enabled": true,
    "confirmation": "DELETE_USER_DATA"
  }

Use explicit uninstall.displayNamePatterns for unwanted apps. Do not attempt a
generic uninstall of every non-Windows program on mixed hardware.

Recommended OOBE workflow
-------------------------
1. Reset Windows: Settings > System > Recovery > Reset this PC > Remove everything.
2. At the first OOBE screen, insert the USB stick.
3. Apply a provisioning package that runs OOBE-Apply.ps1.
4. Let OOBE finish.
5. Log in once as the configured player account.
6. Sign into Minecraft Launcher with a licensed Minecraft account and choose the configured Forge profile.

Manual fallback workflow
------------------------
Use this if OOBE provisioning is unreliable on a given Windows Home build.

1. Complete Windows first-run setup manually.
2. Create the local admin/player accounts manually, or run OOBE-Apply.ps1 from an elevated PowerShell session.
3. Insert the USB stick.
4. Right-click Run-Setup.cmd and choose "Run as administrator".
5. Log in once as the player account so per-user Minecraft setup can run.

USB folder layout
-----------------
USB:\
  Run-Setup.cmd
  Run-Reprovision-Existing.cmd
  Run-Rebuild-Existing.cmd
  Run-Forge-ModpackOnly.cmd
  Start-Reset-Helper.cmd
  PreReset-Check-And-Launch.ps1
  OOBE-Apply.ps1
  Reprovision-Existing-Windows.ps1
  Install-Forge-ModpackOnly.ps1
  Install-Minecraft189.ps1
  README-USB-layout.txt
  README-provisioning-package-optional.txt
  payload\
    config.json
    local-secrets.psd1                 local only; do not commit
    local-secrets.example.psd1
    mods\
      <mod jars listed in config.json>
    installers\
      optional tested Minecraft Launcher offline installer
      roblox-studio\
        optional tested Roblox Studio offline installer
    forge-template\
      versions\
        <Forge version folder from golden machine>
      libraries\
        <libraries folder from golden machine>
      assets\
        optional assets folder from golden machine

Creating payload\forge-template
-------------------------------
Forge 1.8.9's old installer is not reliable for unattended installs. The reliable method is:

1. On one test PC, install the Minecraft Launcher.
2. Install Forge manually once.
3. Launch the Forge profile once and confirm the modpack works.
4. Open %APPDATA%\.minecraft.
5. Copy the Forge version folder into:
   USB:\payload\forge-template\versions\
6. Copy the libraries folder into:
   USB:\payload\forge-template\libraries\
7. Copy the assets folder into:
   USB:\payload\forge-template\assets\

Configuration
-------------
Edit payload\config.json for:

- local account names
- target player account for per-user setup
- Forge version id
- launcher profile name
- Java memory args
- extra apps such as Roblox Studio
- conservative cleanup settings
- optional destructive cleanup and configured app uninstall settings
- mod file list and optional SHA256 hashes

Generate a mod hash on Windows with:

  Get-FileHash .\SomeMod.jar -Algorithm SHA256

Increment setupVersion when you change the modpack and want existing user profiles to re-run setup.

Notes
-----
- Run-Forge-ModpackOnly.cmd only copies Forge/modpack files for the current user.
  It is useful when Minecraft Launcher and Java are already installed.
- The script prefers a local Minecraft Launcher installer from payload\installers.
- Roblox Studio is configured as an extra machine-phase app in payload\config.json.
- If no local app installer is found, the script falls back to the configured WinGet package id.
- It copies the package to C:\ProgramData\MinecraftModpackSetup so the USB is not needed later.
- Per-user setup runs through Windows Active Setup when the configured player logs in.
- Logs are written to C:\ProgramData\MinecraftModpackSetup\Logs or the USB logs folder.
- It does not sign into Minecraft accounts. Each player still needs a licensed account.
