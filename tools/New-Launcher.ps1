# Build a branded, windowless launcher using the .NET Framework shipped with Windows.
[CmdletBinding()]
param(
    [string] $OutputPath,
    [string] $IconPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot 'DriveRelay.exe' }
if (-not $IconPath) { $IconPath = Join-Path $projectRoot 'assets\DriveRelay.ico' }
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }

& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll `
    "/win32icon:$IconPath" "/out:$OutputPath" (Join-Path $PSScriptRoot 'DriveRelayLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw "DriveRelay launcher compilation failed (exit $LASTEXITCODE)." }
