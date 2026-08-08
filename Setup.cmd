@echo off
setlocal EnableExtensions

rem ---------------------------------------------------------------------------
rem  Setup.cmd  --  double-clickable installer for DriveRelay.
rem
rem  Install.ps1 does the real work. This exists because a .ps1 cannot be
rem  double-clicked: Windows opens it in Notepad, and the default execution
rem  policy blocks it even from a console. This wrapper starts PowerShell with
rem  the policy scoped to the one process, so nothing about the machine is
rem  changed.
rem
rem  Everything installs under the current user. No administrator rights, no
rem  services, no registry writes beyond what a shortcut implies.
rem
rem  Any arguments are passed straight through to Install.ps1, so:
rem      Setup.cmd -IntervalMinutes 5
rem      Setup.cmd -NoAutoStart
rem ---------------------------------------------------------------------------

cd /d "%~dp0"

echo.
echo  DriveRelay setup
echo  ----------------
echo  Folder: %~dp0
echo.

rem --- PowerShell present? ---------------------------------------------------

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo  ERROR: powershell.exe was not found on the PATH.
    echo  DriveRelay is written in PowerShell and cannot run without it.
    echo.
    pause
    exit /b 1
)

rem --- the payload has to actually be here -----------------------------------

if not exist "%~dp0Install.ps1" (
    echo  ERROR: Install.ps1 is missing from this folder.
    echo  Extract the whole DriveRelay folder before running Setup.
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0DriveRelayTray.ps1" (
    echo  ERROR: DriveRelayTray.ps1 is missing from this folder.
    echo  Extract the whole DriveRelay folder before running Setup.
    echo.
    pause
    exit /b 1
)

rem --- run the installer -----------------------------------------------------

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo  Setup failed with exit code %RC%. Nothing has been started.
    echo.
    pause
    exit /b %RC%
)

rem --- offer to start it now -------------------------------------------------

echo.
choice /c YN /n /m "  Start DriveRelay now? [Y/N] "
if errorlevel 2 goto :done

if exist "%~dp0DriveRelayTray.vbs" (
    start "" wscript.exe "%~dp0DriveRelayTray.vbs"
    echo.
    echo  Started. Look for the DriveRelay icon by the clock -- Windows 11 hides
    echo  new tray icons behind the chevron until you drag them out.
) else (
    echo.
    echo  DriveRelayTray.vbs was not created; skipping start.
)

:done
echo.
echo  Done. To remove DriveRelay later, run Uninstall.cmd in this folder.
echo.
pause
endlocal
exit /b 0
