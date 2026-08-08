# Test-DriveRelay.ps1 -- Automated test harness for DriveRelay core and settings modules

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $testDir

Write-Host "=== DriveRelay Automated Test Harness ===" -ForegroundColor Cyan
Write-Host "Root: $root"
Write-Host ''

$script:Passed = 0
$script:Failed = 0

function Assert-Equal($actual, $expected, [string]$testName) {
    if ($actual -eq $expected) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] ${testName}: expected '$expected', got '$actual'" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True([bool]$condition, [string]$testName) {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $testName" -ForegroundColor Red
        $script:Failed++
    }
}

# ------------------------------------------------------------- 1. Settings ---
Write-Host "1. Testing lib/Settings.ps1" -ForegroundColor Yellow
. (Join-Path $root 'lib\Settings.ps1')

$tmpSettingsPath = Join-Path $testDir 'test-settings.json'
if (Test-Path $tmpSettingsPath) { Remove-Item -LiteralPath $tmpSettingsPath -Force }
Set-SettingsPath $tmpSettingsPath

$defaultSettings = Get-AppSettings
Assert-Equal $defaultSettings.IntervalMinutes 10 "Default IntervalMinutes is 10"
Assert-Equal $defaultSettings.SettleMinutes 3 "Default SettleMinutes is 3"
Assert-Equal $defaultSettings.MaxDelete 50 "Default MaxDelete is 50"
Assert-Equal $defaultSettings.HydrateBeforeDelete $true "Default HydrateBeforeDelete is true"

$defaultSettings.SettleMinutes = 5
$defaultSettings.IntervalMinutes = 15
Save-AppSettings -Settings $defaultSettings

$reloaded = Get-AppSettings
Assert-Equal $reloaded.SettleMinutes 5 "Persisted SettleMinutes is 5"
Assert-Equal $reloaded.IntervalMinutes 15 "Persisted IntervalMinutes is 15"

$null = Set-AppSetting -Key 'SettleMinutes' -Value 7
$reloaded2 = Get-AppSettings
Assert-Equal $reloaded2.SettleMinutes 7 "Set-AppSetting updated SettleMinutes to 7"

if (Test-Path $tmpSettingsPath) { Remove-Item -LiteralPath $tmpSettingsPath -Force }

# ------------------------------------------------------------- 2. Registry ---
Write-Host "2. Testing lib/Registry.ps1" -ForegroundColor Yellow
. (Join-Path $root 'lib\Provider.ps1')
. (Join-Path $root 'lib\Registry.ps1')

$tmpRegistryPath = Join-Path $testDir 'test-links.json'
if (Test-Path $tmpRegistryPath) { Remove-Item -LiteralPath $tmpRegistryPath -Force }
Set-RegistryPath $tmpRegistryPath

$tmpLocal = Join-Path $testDir 'scratch_local'
$tmpRemote = Join-Path $testDir 'scratch_remote'
if (-not (Test-Path $tmpLocal)) { New-Item -ItemType Directory -Path $tmpLocal -Force | Out-Null }
if (-not (Test-Path $tmpRemote)) { New-Item -ItemType Directory -Path $tmpRemote -Force | Out-Null }

$link = Add-Link -Local $tmpLocal -Remote $tmpRemote -Seed 'Local' -SettleMinutes 5 -MaxDelete 100 -HydrateBeforeDelete $true
Assert-Equal $link.SettleMinutes 5 "Add-Link custom SettleMinutes is 5"
Assert-Equal $link.MaxDelete 100 "Add-Link custom MaxDelete is 100"
Assert-Equal $link.HydrateBeforeDelete $true "Add-Link custom HydrateBeforeDelete is true"

$updated = Set-LinkSettings -Id $link.Id -SettleMinutes 2 -MaxDelete 25
Assert-Equal $updated.SettleMinutes 2 "Set-LinkSettings updated SettleMinutes to 2"
Assert-Equal $updated.MaxDelete 25 "Set-LinkSettings updated MaxDelete to 25"

Remove-Link -Id $link.Id
$allLinks = @(Get-LinkRegistry)
Assert-Equal $allLinks.Count 0 "Remove-Link successfully removed link"

if (Test-Path $tmpLocal) { Remove-Item -LiteralPath $tmpLocal -Recurse -Force }
if (Test-Path $tmpRemote) { Remove-Item -LiteralPath $tmpRemote -Recurse -Force }
if (Test-Path $tmpRegistryPath) { Remove-Item -LiteralPath $tmpRegistryPath -Force }

# ------------------------------------------------------------- 3. Icons ---
Write-Host "3. Testing lib/Icons.ps1" -ForegroundColor Yellow
. (Join-Path $root 'lib\Icons.ps1')

$icoIdle = New-SyncIcon -Size 32 -State 'idle'
Assert-True ($null -ne $icoIdle) "New-SyncIcon generated idle icon"
if ($icoIdle) { $icoIdle.Dispose() }

$icoSync = New-SyncIcon -Size 32 -State 'sync'
Assert-True ($null -ne $icoSync) "New-SyncIcon generated sync icon"
if ($icoSync) { $icoSync.Dispose() }

$icoWarn = New-SyncIcon -Size 32 -State 'warn'
Assert-True ($null -ne $icoWarn) "New-SyncIcon generated warn icon"
if ($icoWarn) { $icoWarn.Dispose() }

# ------------------------------------------------------------- 4. CLI Config ---
Write-Host "4. Testing DriveRelay CLI config command" -ForegroundColor Yellow
$cliPath = Join-Path $root 'DriveRelay.ps1'
$cliOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cliPath config -SettleMinutes 3
$cliOutStr = $cliOut -join "`n"
Assert-True ($cliOutStr -match 'DriveRelay Configuration') "CLI config command displays configuration output"

# Summary
Write-Host ''
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Test Results: $script:Passed Passed, $script:Failed Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "=========================================" -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
