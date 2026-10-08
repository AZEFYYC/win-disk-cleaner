@echo off
rem ============================================================
rem  Disk Temp Cleaner - Windows launcher
rem  Double-click this file to run the interactive menu.
rem  The PowerShell script asks for administrator rights by itself.
rem
rem  Advanced usage (no menu, with arguments) - run in an
rem  administrator PowerShell window instead:
rem      powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -Deep -Yes
rem      powershell -ExecutionPolicy Bypass -File CleanTemp.ps1 -DryRun -Deep
rem ============================================================
setlocal
title Disk Temp Cleaner
cd /d "%~dp0"

if not exist "CleanTemp.ps1" (
    echo [ERROR] CleanTemp.ps1 not found in this folder.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CleanTemp.ps1"
set "RC=%errorlevel%"

rem 42 = the script handed over to an elevated copy in a new window
if "%RC%"=="42" exit /b 0

echo.
if not "%RC%"=="0" (
    echo [INFO] CleanTemp.ps1 exited with code %RC%.
    echo [INFO] Tip: right-click this file and choose "Run as administrator".
)
pause
exit /b %RC%
