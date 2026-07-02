@echo off
setlocal

:: Installs only Forge files, mods, assets, and the Launcher profile
:: for the currently logged-in Windows user.
:: Do not run this elevated unless the admin account is the account that will play.

set "SCRIPT=%~dp0Install-Forge-ModpackOnly.ps1"

if not exist "%SCRIPT%" (
  echo Could not find "%SCRIPT%".
  pause
  exit /b 1
)

echo This will configure Minecraft for the current Windows user:
echo   %USERNAME%
echo.
echo If this is not the player account, close this window and log in as the player first.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if %errorlevel% neq 0 (
  echo.
  echo Forge/modpack-only setup failed. Review the logs folder.
  pause
  exit /b 1
)

echo.
echo Forge/modpack-only setup finished. Review the logs folder if something failed.
pause
