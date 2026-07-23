# EDUTAIN Laptop Toolkit

A small USB-based toolkit for preparing existing Windows laptops without
resetting or reinstalling Windows.

The toolkit provides four choices:

1. Clean up disposable Windows files.
2. Install a Minecraft pack for the current Windows user.
3. Install Roblox Studio.
4. Exit.

The included Minecraft pack definition is **ComputerCraft Edu Pack for
Minecraft 1.8.9**. More packs and Minecraft versions can be added as
self-contained folders.

## Important behavior

- Run the toolkit while signed in as the Windows account that will play
  Minecraft.
- Cleanup requests Administrator permission because it clears system caches.
- Offline Java and Minecraft Launcher installers may also request Administrator
  permission.
- Minecraft files are still written to the original player's
  `%APPDATA%\.minecraft` folder.
- Installing a Minecraft pack permanently removes **everything** currently in
  that player's `.minecraft\mods` folder, then copies only the selected pack's
  mods.
- The pack payload is validated before the existing mods are removed.
- Cleanup does not delete documents and does not uninstall applications.

## Prepare the USB payload

Copy the complete `minecraft_usb_automation` directory to the USB drive. Then
fill these ignored payload directories.

### ComputerCraft Edu Pack

Use the working golden machine as the source. Close Minecraft and Minecraft
Launcher first.

| Golden machine source | USB destination |
| --- | --- |
| `%APPDATA%\.minecraft\versions\1.8.9-forge1.8.9-11.15.1.2318-1.8.9` | `payload\minecraft-packs\computercraft-edu-1.8.9\versions\1.8.9-forge1.8.9-11.15.1.2318-1.8.9` |
| `%APPDATA%\.minecraft\libraries` contents | `payload\minecraft-packs\computercraft-edu-1.8.9\libraries` |
| `%APPDATA%\.minecraft\assets` contents | `payload\minecraft-packs\computercraft-edu-1.8.9\assets` |
| The five tested mod `.jar` files | `payload\minecraft-packs\computercraft-edu-1.8.9\mods` |

The expected mod file names and Forge version ID are listed in
`payload\minecraft-packs\computercraft-edu-1.8.9\pack.json`. Change that file if
the golden machine uses different exact names.

Assets are optional, but bundling them reduces downloads on each laptop.
Libraries and the configured version folder are required.

### Offline installers

Offline installers are preferred when present:

| Application | Destination |
| --- | --- |
| Minecraft Launcher | `payload\installers\minecraft-launcher` |
| Java 8 runtime | `payload\installers\java8` |
| Roblox Studio | `payload\installers\roblox-studio` |

If no matching offline installer exists, the toolkit tries the configured
WinGet package. Edit `payload\config.json` to change installer file patterns,
silent arguments, detection patterns, or WinGet IDs.

Test each offline installer on one laptop before using it across the full set.
Installer command-line behavior can differ between vendor releases.

## Run it

1. Sign in as the Windows user who will play Minecraft.
2. Insert the USB drive.
3. Double-click `minecraft_usb_automation\Run-Toolkit.cmd`.
4. Choose the required actions from the menu.
5. For a Minecraft pack, type `INSTALL` when asked to confirm replacement of
   the current mods folder.
6. Open Minecraft Launcher, sign in, select `ComputerCraft Edu 1.8.9`, and
   launch it once.

Actions are independent. For example, Roblox Studio can be installed without
running cleanup or installing Minecraft.

Every run writes a timestamped transcript under
`minecraft_usb_automation\logs`.

## Add another Minecraft pack

Copy the directory:

```text
payload\minecraft-packs\computercraft-edu-1.8.9
```

Give the copy a unique folder name, remove the copied binary payload, and edit
its `pack.json`:

- `id`: unique stable ID used by command-line automation
- `name`: text shown in the menu
- `profileKey`: unique key in `launcher_profiles.json`
- `profileName`: name shown by Minecraft Launcher
- `versionId`: exact directory name under the pack's `versions` folder
- `javaArgs`: memory and JVM arguments
- `mods`: exact mod file names and optional SHA256 hashes
- `copyAssets` and `requireAssets`: asset-copy behavior

Then add that pack's exact `versions`, `libraries`, `mods`, and optional
`assets` payload. The toolkit discovers enabled `pack.json` files
automatically; no PowerShell changes are needed.

## Optional command-line use

The menu is the normal entry point. These commands are useful for repeatable
deployment:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Laptop-Toolkit.ps1 -Action Cleanup -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Laptop-Toolkit.ps1 -Action MinecraftPack -PackId computercraft-edu-1.8.9 -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Laptop-Toolkit.ps1 -Action RobloxStudio -Force
```

`-Force` skips the Minecraft mod-replacement confirmation. Use it only when
that destructive behavior is intended.

## Public repository hygiene

The `.gitignore` excludes:

- installer binaries
- mod `.jar` files
- copied Minecraft assets, libraries, and version files
- logs

Pack metadata, scripts, documentation, and placeholder files remain tracked.
Do not commit licensed or third-party binaries unless their licenses explicitly
allow redistribution.
