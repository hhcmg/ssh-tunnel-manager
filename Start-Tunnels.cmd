@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tunnels.ps1" %*
set "TUNNEL_EXIT=%ERRORLEVEL%"
if not "%~1"=="" exit /b %TUNNEL_EXIT%
echo.
if not "%TUNNEL_EXIT%"=="0" (
    echo Some checks failed. Review the messages above and the worker logs in the .runtime subfolder.
    echo Active background workers continue automatic recovery; see their logs for status.
    pause
    exit /b %TUNNEL_EXIT%
)
echo Done. This window will close in 5 seconds.
echo Background workers will keep the tunnels connected and reconnect after SSH disconnects.
timeout /t 5 /nobreak >nul
exit /b 0
