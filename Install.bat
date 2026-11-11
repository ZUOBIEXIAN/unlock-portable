@echo off
setlocal
title unlock - Install or Update
echo Installing/updating unlock from this package.
echo All file extensions are scanned by header. No Node.js required.
echo Old unlock scripts will be cleaned after setup. Node.js, npm and other software will be kept.
if not exist "%~dp0setup\install.ps1" (
  echo Missing setup\install.ps1. Extract the complete package before running this BAT.
  pause
  exit /b 1
)
if not exist "%~dp0bin\unlock-core.ps1" (
  echo Missing bin\unlock-core.ps1. Extract the complete package before running this BAT.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\install.ps1"
if errorlevel 1 (
  echo Installation/update failed. See the message above.
  pause
  exit /b 1
)
echo Installation/update completed. Close old terminals and open a new PowerShell window.
pause
exit /b 0
