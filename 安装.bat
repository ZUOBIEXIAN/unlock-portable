@echo off
setlocal
echo Installing the PowerShell version of unlock. No Node.js required.
echo Old unlock scripts will be cleaned after setup. Node.js, npm and other software will be kept.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\install.ps1"
if errorlevel 1 (
  echo Installation failed. See the message above.
  pause
  exit /b 1
)
pause
exit /b 0
