@echo off
setlocal

:: Optional helper. This DOES NOT fully automate Reset this PC.
:: It saves basic activation/edition info to the USB, checks Windows RE, then opens the Reset UI.

set "SCRIPT=%~dp0PreReset-Check-And-Launch.ps1"
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
pause
