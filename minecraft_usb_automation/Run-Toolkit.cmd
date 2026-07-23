@echo off
setlocal

set "SCRIPT=%~dp0Laptop-Toolkit.ps1"

if not exist "%SCRIPT%" (
  echo Could not find "%SCRIPT%".
  pause
  exit /b 1
)

echo Starting the laptop setup toolkit for Windows user: %USERNAME%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

if %errorlevel% neq 0 (
  echo.
  echo The toolkit stopped with an error. Review the newest file in the logs folder.
)

echo.
pause
