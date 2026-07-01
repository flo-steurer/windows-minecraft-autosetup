Windows Configuration Designer / OOBE provisioning
==================================================

For this project, OOBE provisioning is the preferred path because it saves the
most repeated clicks across ~30 laptops.

Windows Home constraint
-----------------------
Many laptops may be Windows Home. Windows Configuration Designer's desktop wizard
is documented for Windows desktop editions except Home, so do not depend on the
wizard's built-in local-account page as the only account-creation mechanism.

Instead, use the provisioning package to run:

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<USB path>\OOBE-Apply.ps1"

OOBE-Apply.ps1 reads payload\config.json and payload\local-secrets.psd1, creates
the configured local admin and player accounts, then runs the machine phase of
Install-Minecraft189.ps1. The machine phase installs Minecraft Launcher and any
enabled extra apps, such as Roblox Studio.

Suggested WCD package
---------------------
1. Install Windows Configuration Designer on a Windows PC.
2. Create a package for Windows desktop devices.
3. Configure only low-risk common settings in the wizard, such as device name
   and Wi-Fi, if they work on your target editions.
4. Add a command/script step that runs OOBE-Apply.ps1.
5. Build the package and place it on the USB with this kit.
6. Test on one Windows Home laptop before using it on all laptops.

Important details
-----------------
- USB drive letters can differ. If WCD cannot reliably run from the USB path,
  include/copy this whole kit as package content first, then run OOBE-Apply.ps1
  from that copied location.
- Do not put real passwords in tracked files. Copy
  payload\local-secrets.example.psd1 to payload\local-secrets.psd1 only on the
  USB or other private deployment media.
- Applying a .ppkg during OOBE may still require confirmation. At the first OOBE
  screen, inserting the USB may trigger it; otherwise press the Windows key five
  times and choose provisioning options.
- Test the full reset -> OOBE -> player login -> Minecraft launch flow before
  doing the other laptops.

Manual fallback
---------------
If a Home machine refuses the OOBE package/script path:

1. Finish OOBE manually.
2. Open PowerShell as administrator.
3. Run:

   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<USB path>\OOBE-Apply.ps1"

This still creates the local accounts and installs the Minecraft machine setup,
but it requires one post-OOBE admin action.
