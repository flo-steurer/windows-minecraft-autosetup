Minecraft/Forge USB automation kit
==================================

Use this after Windows Reset, ideally through OOBE provisioning.

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
  Start-Reset-Helper.cmd
  PreReset-Check-And-Launch.ps1
  OOBE-Apply.ps1
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
- mod file list and optional SHA256 hashes

Generate a mod hash on Windows with:

  Get-FileHash .\SomeMod.jar -Algorithm SHA256

Increment setupVersion when you change the modpack and want existing user profiles to re-run setup.

Notes
-----
- The script prefers a local Minecraft Launcher installer from payload\installers.
- Roblox Studio is configured as an extra machine-phase app in payload\config.json.
- If no local app installer is found, the script falls back to the configured WinGet package id.
- It copies the package to C:\ProgramData\MinecraftModpackSetup so the USB is not needed later.
- Per-user setup runs through Windows Active Setup when the configured player logs in.
- Logs are written to C:\ProgramData\MinecraftModpackSetup\Logs or the USB logs folder.
- It does not sign into Minecraft accounts. Each player still needs a licensed account.
