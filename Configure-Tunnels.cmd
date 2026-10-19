@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tunnels.ps1" -Configure %*
set "TUNNEL_EXIT=%ERRORLEVEL%"
if not "%~1"=="" exit /b %TUNNEL_EXIT%
echo.
pause
exit /b %TUNNEL_EXIT%
