' Launches the DriveRelay tray agent without a console window.
Dim fso, scriptDir, shell, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\DriveRelayTray.ps1"""
shell.Run cmd, 0, False
