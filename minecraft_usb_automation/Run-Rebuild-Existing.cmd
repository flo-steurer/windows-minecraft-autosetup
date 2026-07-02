@echo off
setlocal

:: Alias for the no-reset rebuild path.
:: Configure payload\config.json before running.

call "%~dp0Run-Reprovision-Existing.cmd"
