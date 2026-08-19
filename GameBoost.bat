@echo off
title GameBoost
setlocal

net session >nul 2>&1
if not %errorlevel%==0 (
    echo Requesting admin rights. Click Yes in the UAC window.
    timeout /t 2 >nul
    powershell -ExecutionPolicy Bypass -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)

cd /d "%~dp0"

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0GameBoost.ps1"

if not %errorlevel%==0 (
    echo.
    echo Startup error. Code: %errorlevel%
    pause
)

endlocal
exit /b
