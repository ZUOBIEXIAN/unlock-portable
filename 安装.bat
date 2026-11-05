@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\install.ps1"
if errorlevel 1 (
  echo Installation failed. See the message above.
  pause
  exit /b 1
)
pause
exit /b 0
