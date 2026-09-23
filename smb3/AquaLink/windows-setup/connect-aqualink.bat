@echo off
rem [2026-09-23] Real-world testing found that running this .bat file itself
rem "as Administrator" makes the network drive it creates invisible in a
rem normal (non-admin) File Explorer window -- Windows keeps drives mapped
rem from an elevated session separate from the regular desktop session.
rem The registry/hosts steps inside setup-aqualink.ps1 already elevate
rem themselves individually (a UAC popup appears only when needed), so this
rem file should always be run as a normal double-click, never "Run as
rem administrator" -- warn clearly if it looks like that happened anyway.
net session >nul 2>&1
if %errorlevel% equ 0 (
    echo ===============================================================
    echo  WARNING: This looks like it's running with Administrator rights.
    echo  Please close this window and double-click connect-aqualink.bat
    echo  normally instead ^(do NOT choose "Run as administrator"^).
    echo  A drive mapped from an elevated window will NOT show up in your
    echo  regular File Explorer, even if this script reports success.
    echo ===============================================================
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-aqualink.ps1"
echo.
pause
