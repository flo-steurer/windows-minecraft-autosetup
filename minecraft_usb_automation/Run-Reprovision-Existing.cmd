@echo off
setlocal

:: Fast no-reset path for existing Windows installs.
:: Runs account creation, machine app setup, and per-user setup registration.

set "SCRIPT=%~dp0Reprovision-Existing-Windows.ps1"

if not exist "%SCRIPT%" (
  echo Could not find "%SCRIPT%".
  pause
  exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator permission...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

echo.
echo Reprovisioning finished. Review the logs folder or C:\ProgramData\MinecraftModpackSetup\Logs if something failed.
pause
