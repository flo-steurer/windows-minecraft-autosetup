# Reset-to-Minecraft Laptop Setup

Reusable USB kit for resetting Windows laptops and preparing a local Minecraft Java/Forge modpack environment.

The intended scale is small batch deployment: roughly tens of laptops.

## Recommended workflow

1. Build one golden machine.
   - Reset Windows.
   - Install Minecraft Launcher.
   - Install and launch the exact Forge version once.
   - Add the mods and verify the profile starts.

2. Copy golden-machine data into the USB payload.
   - Copy `%APPDATA%\.minecraft\versions\<forge version id>` to `minecraft_usb_automation\payload\forge-template\versions\`.
   - Copy `%APPDATA%\.minecraft\libraries` to `minecraft_usb_automation\payload\forge-template\libraries`.
   - Copy `%APPDATA%\.minecraft\assets` to `minecraft_usb_automation\payload\forge-template\assets` if you want first launch to work with minimal downloads.
   - Copy mod `.jar` files to `minecraft_usb_automation\payload\mods`.
   - Put a tested offline Minecraft Launcher installer in `minecraft_usb_automation\payload\installers` when possible.
   - Put a tested Roblox Studio installer in `minecraft_usb_automation\payload\installers\roblox-studio` when possible.

3. Edit `minecraft_usb_automation\payload\config.json`.
   - Change account names under `windows`.
   - Change Forge/profile settings under `minecraft`.
   - Change the `mods` list for a different modpack.
   - Change or disable Roblox Studio under `extraApps`.
   - Optionally fill each mod's `sha256`; generate it on Windows with `Get-FileHash <file> -Algorithm SHA256`.
   - Increment `setupVersion` when you want already-provisioned user profiles to re-run setup.

4. Create USB-local secrets.
   - Copy `minecraft_usb_automation\payload\local-secrets.example.psd1` to `minecraft_usb_automation\payload\local-secrets.psd1`.
   - Fill in `AdminPassword`.
   - Leave `PlayerPassword` blank only if you intentionally want the player account to have no password.

5. Choose a deployment path.
   - Fast path: keep Windows and run `minecraft_usb_automation\Run-Reprovision-Existing.cmd` as administrator.
   - Cleanest path: reset each laptop with Settings > System > Recovery > Reset this PC > Remove everything.

6. For the reset path, during OOBE, apply a provisioning package that runs:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path-to-usb>\OOBE-Apply.ps1"
   ```

7. For the no-reset path, sign out and log in once as the configured player account.
   - The per-user Minecraft setup runs via Windows Active Setup.
   - Start Minecraft Launcher, sign in with a licensed account, and select the configured Forge profile.

## Fast no-reset path

Use this when Windows Reset is too slow.

The fastest reliable approach is not to deeply clean every old Windows install. Instead:

1. Keep the existing Windows installation.
2. Run conservative disk cleanup from an existing admin account.
3. Create or update the configured local admin account.
4. Create a fresh standard player account.
5. Install Minecraft Launcher, Roblox Studio, Forge files, and mods.
6. Only let children use the standard player account.

For the cleanest result, set `windows.playerUserName` in `payload\config.json` to an account name that does not already exist on the laptop, for example `Player2026`. A new Windows account gets a fresh profile, so old browser files, old Minecraft config, old downloads, and old app data from previous users do not carry over into the child account.

Run this on each laptop from an existing admin account:

```text
minecraft_usb_automation\Run-Reprovision-Existing.cmd
```

Then sign out and log in as the configured player account.

The no-reset script cleans temp folders, recycle bin, Windows Update download cache, and Delivery Optimization cache. It does not delete documents, downloads, old user profiles, or installed apps. You can change cleanup behavior under `cleanup` in `payload\config.json`; keep `runComponentCleanup` disabled unless you can afford a slower DISM cleanup pass.

### Aggressive no-reset mode

The script can also be configured to behave more like a rebuild, but it is intentionally opt-in.

In `payload\config.json`:

- `destructiveCleanup.enabled`: set to `true` only when you really want destructive cleanup.
- `destructiveCleanup.confirmation`: must be exactly `DELETE_USER_DATA`.
- `destructiveCleanup.deleteExistingPlayerProfile`: deletes the configured player profile so the next login recreates default Windows settings for that player.
- `destructiveCleanup.deleteKnownUserDataFolders`: deletes configured folders such as Desktop, Documents, Downloads, Pictures, Videos, and Music from non-excluded profiles.
- `uninstall.enabled`: removes only programs matching `uninstall.displayNamePatterns`; it does not blindly remove every non-Windows app.

Do not try to uninstall "everything extra" generically. On mixed laptops, that can remove drivers, OEM utilities, school management tools, Office/licensing pieces, or GPU/Wi-Fi support. Use the explicit uninstall patterns for known unwanted apps.

Java 8 is configured as an extra app. Put a tested Java 8 installer in `payload\installers\java8`, or verify the configured WinGet package id on one test laptop before relying on network installation.

## Reset path

If you still want the cleanest OS state:

1. Reset each laptop.
   - Settings > System > Recovery > Reset this PC > Remove everything.
   - Local reinstall is usually enough if Windows itself is healthy.

2. During OOBE, apply a provisioning package that runs:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path-to-usb>\OOBE-Apply.ps1"
   ```

3. Log in once as the player account.
   - The per-user Minecraft setup runs via Windows Active Setup.
   - Start Minecraft Launcher, sign in with a licensed account, and select the configured Forge profile.

## Windows Home note

Assume Windows Home is the baseline unless you have confirmed otherwise.

Windows Configuration Designer's desktop provisioning wizard is documented for desktop editions except Home. For Home-heavy fleets, use the provisioning package mainly as a launcher for `OOBE-Apply.ps1`. That script creates the local admin and player accounts itself, using standard local Windows user commands, then runs the machine phase of the Minecraft setup.

If a provisioning package will not run your script reliably on a specific Home build, fall back to completing OOBE manually once, then run `minecraft_usb_automation\Run-Setup.cmd` as administrator. That fallback still creates the Minecraft machine setup and per-user setup hook, but account creation may need to be done manually or by running `OOBE-Apply.ps1` from an elevated PowerShell session.

## Public repo hygiene

Do not commit:

- `payload\local-secrets.psd1`
- Minecraft Launcher installers
- Roblox Studio installers
- Mod `.jar` files
- copied Forge libraries, versions, or assets
- setup logs

Those paths are ignored in `.gitignore`.

## Main files

- `minecraft_usb_automation\OOBE-Apply.ps1`: OOBE/provisioning entry point. Creates accounts and runs machine setup.
- `minecraft_usb_automation\Run-Reprovision-Existing.cmd`: fast no-reset path for existing Windows installs.
- `minecraft_usb_automation\Run-Rebuild-Existing.cmd`: alias for the no-reset rebuild path.
- `minecraft_usb_automation\Reprovision-Existing-Windows.ps1`: script behind the no-reset path.
- `minecraft_usb_automation\Run-Forge-ModpackOnly.cmd`: current-user Forge/mod copy only; does not install Launcher, Java, Roblox, or accounts.
- `minecraft_usb_automation\Install-Forge-ModpackOnly.ps1`: script behind the Forge/mod-only path.
- `minecraft_usb_automation\Install-Minecraft189.ps1`: machine and per-user Minecraft setup.
- `minecraft_usb_automation\payload\config.json`: reusable modpack/account configuration.
- `minecraft_usb_automation\Run-Setup.cmd`: manual fallback after Windows first-run setup.
- `minecraft_usb_automation\Start-Reset-Helper.cmd`: optional pre-reset helper that records activation/recovery info and opens Reset this PC.
