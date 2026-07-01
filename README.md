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

3. Edit `minecraft_usb_automation\payload\config.json`.
   - Change account names under `windows`.
   - Change Forge/profile settings under `minecraft`.
   - Change the `mods` list for a different modpack.
   - Optionally fill each mod's `sha256`; generate it on Windows with `Get-FileHash <file> -Algorithm SHA256`.
   - Increment `setupVersion` when you want already-provisioned user profiles to re-run setup.

4. Create USB-local secrets.
   - Copy `minecraft_usb_automation\payload\local-secrets.example.psd1` to `minecraft_usb_automation\payload\local-secrets.psd1`.
   - Fill in `AdminPassword`.
   - Leave `PlayerPassword` blank only if you intentionally want the player account to have no password.

5. Reset each laptop.
   - Settings > System > Recovery > Reset this PC > Remove everything.
   - Local reinstall is usually enough if Windows itself is healthy.

6. During OOBE, apply a provisioning package that runs:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path-to-usb>\OOBE-Apply.ps1"
   ```

7. Log in once as the player account.
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
- Mod `.jar` files
- copied Forge libraries, versions, or assets
- setup logs

Those paths are ignored in `.gitignore`.

## Main files

- `minecraft_usb_automation\OOBE-Apply.ps1`: OOBE/provisioning entry point. Creates accounts and runs machine setup.
- `minecraft_usb_automation\Install-Minecraft189.ps1`: machine and per-user Minecraft setup.
- `minecraft_usb_automation\payload\config.json`: reusable modpack/account configuration.
- `minecraft_usb_automation\Run-Setup.cmd`: manual fallback after Windows first-run setup.
- `minecraft_usb_automation\Start-Reset-Helper.cmd`: optional pre-reset helper that records activation/recovery info and opens Reset this PC.
