<# Build the distributable without reading private runtime configuration/state.
   Requires Inno Setup 6; the installed application needs only Windows PowerShell.
   Each build keeps its unique staging tree and payload inventory for inspection.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string] $Version = '1.0.0',
    [string] $OutputDirectory,
    [string] $CompilerPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $CompilerPath) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $CompilerPath = $command.Source }
    else {
        foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if (-not $base) { continue }
            $candidate = Join-Path $base 'Inno Setup 6\ISCC.exe'
            if (Test-Path -LiteralPath $candidate) { $CompilerPath = $candidate; break }
        }
    }
}
if (-not $CompilerPath -or -not (Test-Path -LiteralPath $CompilerPath)) {
    throw 'Inno Setup 6 was not found. Install it or supply -CompilerPath to ISCC.exe.'
}

# Deliberately not a recursive copy of the checkout. New dependencies must be
# listed explicitly so local config, logs, histories and scratch files stay out.
$payloadFiles = @(
    'DriveRelay.ps1', 'DriveRelayTray.ps1', 'DriveRelayUI.ps1',
    'README.md', 'LICENSE', 'DriveRelay.ico', 'assets\DriveRelay.ico',
    'docs\04-operations.md', 'docs\06-audit.md',
    'config\excludes.txt', 'config\links.example.json', 'config\settings.example.json',
    'lib\Actions.ps1', 'lib\Availability.ps1', 'lib\Conflicts.ps1',
    'lib\DashboardScan.ps1', 'lib\FileIdentity.ps1', 'lib\Hydration.ps1',
    'lib\Icons.ps1', 'lib\Logging.ps1', 'lib\LogViewer.ps1', 'lib\Manifest.ps1',
    'lib\Pass.ps1', 'lib\Provider.ps1', 'lib\Registry.ps1',
    'lib\Settings.ps1', 'lib\Settle.ps1', 'tools\Configure-Install.ps1'
)

$stage = Join-Path (Join-Path $projectRoot 'build\installer') ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($relativePath in $payloadFiles) {
    $source = Join-Path $projectRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing payload file: $relativePath" }
    $target = Join-Path $stage $relativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -ErrorAction Stop
}

# Rebuild in staging; never ship a stale exe or replace the live launcher's file.
& (Join-Path $PSScriptRoot 'New-Launcher.ps1') -OutputPath (Join-Path $stage 'DriveRelay.exe') -IconPath (Join-Path $stage 'assets\DriveRelay.ico')

# Fail the build if a staged script references a missing sibling module. This
# catches future runtime dependencies omitted from the explicit allowlist.
foreach ($file in Get-ChildItem -LiteralPath $stage -Filter *.ps1 -Recurse -File) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($match in [regex]::Matches($text, "'(?<dependency>(?:lib\\)?[A-Za-z][A-Za-z0-9-]*\.ps1)'")) {
        $dependency = $match.Groups['dependency'].Value
        $resolved = if ($dependency.StartsWith('lib\')) { Join-Path $stage $dependency }
                    else { Join-Path $file.DirectoryName $dependency }
        # Other scripts may refer to an entry point at the application root.
        if (-not (Test-Path -LiteralPath $resolved)) { $resolved = Join-Path $stage $dependency }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "Unpackaged script dependency in $($file.Name): $dependency"
        }
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$inventory = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{
        Path = $_.FullName.Substring($stage.Length + 1)
        Bytes = $_.Length
        SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$manifestPath = Join-Path $OutputDirectory "DriveRelay-$Version-payload.json"
ConvertTo-Json -InputObject $inventory -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

& $CompilerPath "/DPayloadDir=$stage" "/DAppVersion=$Version" "/O$OutputDirectory" (Join-Path $PSScriptRoot 'DriveRelay.iss') | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed (exit $LASTEXITCODE)." }
$installerPath = Join-Path $OutputDirectory "DriveRelay-Setup-$Version.exe"
if (-not (Test-Path -LiteralPath $installerPath)) { throw 'Compiler did not produce the expected installer.' }
$hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
Set-Content -LiteralPath "$installerPath.sha256" -Value "$hash  $([IO.Path]::GetFileName($installerPath))" -Encoding ASCII

[pscustomobject]@{ Installer = $installerPath; SHA256 = $hash; PayloadManifest = $manifestPath; StagingDirectory = $stage }
