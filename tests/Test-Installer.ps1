# Compile the release, then exercise the same template with all OS integration
# remapped into a unique scratch directory. Never install into the live checkout,
# replace the user's shortcuts, or register a test in Windows Installed Apps.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$build = & (Join-Path $projectRoot 'tools\New-Installer.ps1')
$testRoot = Join-Path $projectRoot ('build\installer-tests\' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$appRoot = Join-Path $testRoot 'App with spaces & symbols'
$passed = 0
function Assert-Installer([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}

$inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $build.PayloadManifest -Raw)
$private = @($inventory | Where-Object { $_.Path -match '(^state\\|\.log$|^config\\(links|settings)\.json$|^tests\\|^\.git)' })
Assert-Installer ($private.Count -eq 0) 'Release payload excludes private state, settings, links, logs and tests'
Assert-Installer ($inventory.Count -eq 29) 'Release has the expected 29 allowlisted files including the rebuilt launcher'
foreach ($entry in $inventory) {
    Assert-Installer ((Get-FileHash -LiteralPath (Join-Path $build.StagingDirectory $entry.Path) -Algorithm SHA256).Hash -eq $entry.SHA256) "Payload checksum: $($entry.Path)"
}
Assert-Installer ((Get-Item -LiteralPath $build.Installer).VersionInfo.ProductName.Trim() -eq 'DriveRelay') 'Installer executable carries the DriveRelay product identity'

$template = Get-Content -LiteralPath (Join-Path $projectRoot 'tools\DriveRelay.iss') -Raw
$testId = [guid]::NewGuid().ToString()
$template = $template -replace '(?m)^AppId=.*$', ('AppId={{' + $testId + '}')
$template = $template -replace '(?m)^AppMutex=.*$', ('AppMutex=Global\DriveRelayInstallerTest-' + $testId)
$template = $template -replace '(?m)^SetupMutex=.*$', ('SetupMutex=DriveRelaySetupTest-' + $testId)
$template = $template -replace '(?m)^DefaultDirName=.*$', ('DefaultDirName=' + $appRoot)
$template = $template.Replace('{group}', (Join-Path $testRoot 'Start Menu'))
$template = $template.Replace('{userstartup}', (Join-Path $testRoot 'Startup'))
$template = $template.Replace('{userdesktop}', (Join-Path $testRoot 'Desktop'))
$template = $template.Replace('[Setup]', "[Setup]`r`nCreateUninstallRegKey=no`r`nUsePreviousAppDir=no`r`nUsePreviousGroup=no`r`nUsePreviousTasks=no")
$testSource = Join-Path $testRoot 'Verify.iss'
Set-Content -LiteralPath $testSource -Value $template -Encoding UTF8
$compiler = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $compiler) { $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
& $compiler /Q "/DPayloadDir=$($build.StagingDirectory)" "/O$testRoot" /FVerify $testSource
if ($LASTEXITCODE -ne 0) { throw 'Verification installer compilation failed.' }
$testInstaller = Join-Path $testRoot 'Verify.exe'

function Invoke-TestSetup([string] $Executable, [string] $Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force
        throw 'Verification setup did not finish within 30 seconds.'
    }
    if ($process.ExitCode -ne 0) { throw "Verification setup failed with exit code $($process.ExitCode). Inspect logs in $testRoot" }
}

# Active-app protection must abort without ever creating the install directory.
$guard = New-Object System.Threading.Mutex($false, ('Global\DriveRelayInstallerTest-' + $testId))
try {
    $blocked = Start-Process -FilePath $testInstaller -ArgumentList ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + (Join-Path $testRoot 'blocked.log') + '"') -WindowStyle Hidden -PassThru
    if (-not $blocked.WaitForExit(15000)) { Stop-Process -Id $blocked.Id -Force; throw 'Mutex rejection did not finish.' }
    Assert-Installer ($blocked.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $appRoot)) 'Active tray/pass mutex prevents installation before files change'
} finally { $guard.Dispose() }

Invoke-TestSetup $testInstaller ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="autostart,desktopicon" /LOG="' + (Join-Path $testRoot 'install.log') + '"')
$launcher = Join-Path $appRoot 'DriveRelay.exe'
$startup = Join-Path $testRoot 'Startup\DriveRelay.lnk'
$desktop = Join-Path $testRoot 'Desktop\DriveRelay.lnk'
Assert-Installer (Test-Path -LiteralPath $launcher) 'Fresh installation copies the application to a path containing spaces and ampersand'
Assert-Installer ((Test-Path -LiteralPath $startup) -and (Test-Path -LiteralPath $desktop)) 'Selected startup and desktop shortcuts are created'
$ws = New-Object -ComObject WScript.Shell
Assert-Installer ($ws.CreateShortcut($startup).TargetPath -eq $launcher) 'Startup shortcut targets the branded launcher'
$settingsPath = Join-Path $appRoot 'config\settings.json'
$settings = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $settingsPath -Raw)
Assert-Installer $settings.StartWithWindows 'Startup task is reflected in application settings'
Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $appRoot 'config\links.json'))) 'Fresh install contains no registered personal links'
$cliOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'DriveRelay.ps1') list
Assert-Installer ($LASTEXITCODE -eq 0) 'Packaged CLI loads its runtime modules and lists fresh links'

# Simulate an existing user installation, then upgrade it without optional icons.
$settings.Paused = $true
$settings.SettleMinutes = 17
$settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
$linksPath = Join-Path $appRoot 'config\links.json'
$statePath = Join-Path $appRoot 'state\baseline.json'
New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
Set-Content -LiteralPath $linksPath -Value '[]' -Encoding UTF8
Set-Content -LiteralPath $statePath -Value '{"sentinel":"history"}' -Encoding UTF8
$excludePath = Join-Path $appRoot 'config\excludes.txt'
Set-Content -LiteralPath $excludePath -Value 'custom-exclude-*.txt' -Encoding UTF8
$logPath = Join-Path $appRoot 'driverelay.log'
Set-Content -LiteralPath $logPath -Value 'user log sentinel' -Encoding UTF8
$retained = @($linksPath, $statePath, $excludePath, $logPath)
$hashes = @{}
foreach ($path in $retained) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }

Invoke-TestSetup $testInstaller ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="!autostart,!desktopicon" /LOG="' + (Join-Path $testRoot 'upgrade.log') + '"')
$settings = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $settingsPath -Raw)
Assert-Installer (-not $settings.StartWithWindows) 'Upgrade applies an unchecked Windows startup option'
Assert-Installer ($settings.Paused -and $settings.SettleMinutes -eq 17) 'Upgrade preserves pause and existing sync preferences'
Assert-Installer (-not (Test-Path -LiteralPath $startup) -and -not (Test-Path -LiteralPath $desktop)) 'Upgrade removes optional shortcuts when unchecked'
foreach ($path in $retained) {
    Assert-Installer ((Get-FileHash -LiteralPath $path).Hash -eq $hashes[$path]) "Upgrade preserves $([IO.Path]::GetFileName($path))"
}

$uninstaller = @(Get-ChildItem -LiteralPath $appRoot -Filter 'unins*.exe' -File)[0].FullName
Invoke-TestSetup $uninstaller ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + (Join-Path $testRoot 'uninstall.log') + '"')
# The uninstaller relaunches from Temp to remove itself; wait for its work.
$deadline = [datetime]::UtcNow.AddSeconds(10)
while ((Test-Path -LiteralPath $launcher) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
Assert-Installer (-not (Test-Path -LiteralPath $launcher)) 'Uninstall removes the installed application'
Assert-Installer (-not (Test-Path -LiteralPath (Join-Path $testRoot 'Start Menu\DriveRelay.lnk'))) 'Uninstall removes the Start Menu shortcut'
foreach ($path in $retained) {
    Assert-Installer ((Get-FileHash -LiteralPath $path).Hash -eq $hashes[$path]) "Uninstall preserves $([IO.Path]::GetFileName($path))"
}
Assert-Installer (Test-Path -LiteralPath $settingsPath) 'Uninstall keeps application preferences for reinstalling'
Write-Host "Installer verification: $passed passed. Logs: $testRoot"
