@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem  Uninstall.cmd  --  double-clickable counterpart to Setup.cmd.
rem
rem  Removes the shortcuts, the launcher and any leftover scheduled task, and
rem  stops the tray agent. Your links, your sync history and every file in every
rem  linked folder are left exactly as they are.
rem
rem  Pass -AlsoRemoveSettings to additionally forget links.json and state\.
rem  Even then, no file inside a linked folder is touched.
rem ---------------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo  DriveRelay uninstall
echo  --------------------
echo.

if not exist "%~dp0Uninstall.ps1" (
    echo  ERROR: Uninstall.ps1 is missing from this folder.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
pause
endlocal
exit /b %RC%
