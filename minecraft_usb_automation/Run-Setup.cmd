@echo off
setlocal

:: Runs the Minecraft 1.8.9 setup script as Administrator.
:: Put this file at the root of the USB stick next to Install-Minecraft189.ps1.

set "SCRIPT=%~dp0Install-Minecraft189.ps1"

if not exist "%SCRIPT%" (
  echo Could not find "%SCRIPT%".
  pause
  exit /b 1
)

:: Check admin. If not elevated, relaunch elevated.
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator permission...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Mode Auto

echo.
echo Setup finished. Review C:\ProgramData\MinecraftModpackSetup\Logs if something failed.
pause
