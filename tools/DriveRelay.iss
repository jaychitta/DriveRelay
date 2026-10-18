; Build with New-Installer.ps1. PayloadDir is an allowlisted, clean staging tree.
#ifndef PayloadDir
  #error PayloadDir must be supplied by New-Installer.ps1
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{65E4437E-411E-4F63-A13C-503D7B12B3BB}
AppName=DriveRelay
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
VersionInfoProductName=DriveRelay
AppPublisher=Jayadheer Chitta
AppCopyright=Copyright (C) 2026 Jayadheer Chitta
DefaultDirName={localappdata}\Programs\DriveRelay
DefaultGroupName=DriveRelay
PrivilegesRequired=lowest
MinVersion=10.0
DisableWelcomePage=no
DisableDirPage=no
DisableProgramGroupPage=yes
WizardStyle=modern
SetupIconFile={#PayloadDir}\assets\DriveRelay.ico
UninstallDisplayIcon={app}\DriveRelay.exe
LicenseFile={#PayloadDir}\LICENSE
OutputBaseFilename=DriveRelay-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
AppMutex=Global\DriveRelayTray,Global\DriveRelayPass
SetupMutex=DriveRelaySetup
CloseApplications=no
RestartApplications=no
UninstallLogging=yes

[Tasks]
Name: "autostart"; Description: "Start DriveRelay when I sign in to Windows"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Excludes: "config\excludes.txt"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#PayloadDir}\config\excludes.txt"; DestDir: "{app}\config"; Flags: onlyifdoesntexist uninsneveruninstall

[InstallDelete]
; Remove an earlier optional shortcut when its task is now unchecked.
Type: files; Name: "{userstartup}\DriveRelay.lnk"
Type: files; Name: "{userdesktop}\DriveRelay.lnk"

[Icons]
Name: "{group}\DriveRelay"; Filename: "{app}\DriveRelay.exe"; WorkingDir: "{app}"; Comment: "Start the DriveRelay tray agent"
Name: "{group}\DriveRelay Dashboard"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\DriveRelayUI.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\DriveRelay.exe"
Name: "{group}\Uninstall DriveRelay"; Filename: "{uninstallexe}"
Name: "{userstartup}\DriveRelay"; Filename: "{app}\DriveRelay.exe"; WorkingDir: "{app}"; Tasks: autostart
Name: "{userdesktop}\DriveRelay"; Filename: "{app}\DriveRelay.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\DriveRelay.exe"; Description: "Start DriveRelay"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  StartupOption: String;
  Parameters: String;
begin
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('autostart') then StartupOption := '1'
    else StartupOption := '0';
    Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\tools\Configure-Install.ps1') + '" -InstallRoot "' +
      ExpandConstant('{app}') + '" -StartWithWindows ' + StartupOption;
    if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Parameters, ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      RaiseException('Could not configure DriveRelay. Windows PowerShell could not start.');
    if ResultCode <> 0 then
      RaiseException('DriveRelay configuration failed. Setup exit code: ' + IntToStr(ResultCode));
  end;
end;
