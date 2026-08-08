# Test-DriveRelay.ps1 -- Automated test harness for DriveRelay core and settings modules

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $testDir

# Redirect logging into the tests folder before anything else runs.
#
# The engine sections below exercise real copies and deletes, and Logging.ps1
# defaults to the repository-root driverelay.log -- the production log of a live
# install. Without this, a test run interleaves fake link ids and scratch paths
# into the operator's actual sync history, which is the record you go to when
# something has gone wrong.
. (Join-Path $root 'lib\Logging.ps1')
$script:TestLog = Join-Path $testDir 'test-run.log'
if (Test-Path $script:TestLog) { Remove-Item -LiteralPath $script:TestLog -Force -ErrorAction SilentlyContinue }
Set-LogPath $script:TestLog

Write-Host "=== DriveRelay Automated Test Harness ===" -ForegroundColor Cyan
Write-Host "Root: $root"
Write-Host "Log:  $script:TestLog  (never the production log)"
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

# ------------------------------------------------------- 5. Overlap guard ---
# Regression test for the chain case: registering A <-> B and then B <-> C used
# to be accepted, leaving two links driving folder B from two manifests.
Write-Host "5. Testing link overlap rejection" -ForegroundColor Yellow

$ovRegistry = Join-Path $testDir 'test-overlap.json'
if (Test-Path $ovRegistry) { Remove-Item -LiteralPath $ovRegistry -Force }
Set-RegistryPath $ovRegistry

$ovBase = Join-Path $testDir 'scratch_overlap'
$ovA = Join-Path $ovBase 'A'; $ovB = Join-Path $ovBase 'B'; $ovC = Join-Path $ovBase 'C'
New-Item -ItemType Directory -Path $ovA, $ovB, $ovC -Force | Out-Null

$null = Add-Link -Local $ovA -Remote $ovB -Seed 'Local'

$chainRejected = $false
try   { $null = Add-Link -Local $ovB -Remote $ovC -Seed 'Local' }
catch { $chainRejected = $true }
Assert-True $chainRejected "Chain A<->B then B<->C is rejected (new local vs existing remote)"

$reverseRejected = $false
try   { $null = Add-Link -Local $ovC -Remote $ovA -Seed 'Local' }
catch { $reverseRejected = $true }
Assert-True $reverseRejected "Chain C<->A is rejected (new remote vs existing local)"

Assert-Equal @(Get-LinkRegistry).Count 1 "Only the first link survived the rejected attempts"

$selfRejected = $false
try   { $null = Add-Link -Local $ovBase -Remote $ovC -Seed 'Local' }
catch { $selfRejected = $true }
Assert-True $selfRejected "A parent folder of an existing link's side is rejected"

Remove-Item -LiteralPath $ovBase -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $ovRegistry) { Remove-Item -LiteralPath $ovRegistry -Force }

# --------------------------------------------------------- 6. Sync engine ---
# The classification table in Compare-LinkState decides copy vs. delete vs.
# conflict. It is the code that can lose data and had no coverage at all --
# the DeleteRemote regression of 2026-08-07 would have been caught here.
Write-Host "6. Testing sync engine classification (lib/Manifest.ps1)" -ForegroundColor Yellow

. (Join-Path $root 'lib\Availability.ps1')   # Actions.ps1 calls Get-LinkAvailability
. (Join-Path $root 'lib\Hydration.ps1')
. (Join-Path $root 'lib\Settle.ps1')
. (Join-Path $root 'lib\Manifest.ps1')
. (Join-Path $root 'lib\Actions.ps1')

# Logging.ps1 is deliberately not re-sourced here: it resets $script:LogPath to
# the production log on load, which would undo the redirect set at the top.
Set-LogPath $script:TestLog

$engineRoot = Join-Path $testDir 'scratch_engine'

function New-TestLink {
    <#
        A scratch link with both sides empty and no manifest.
        SettleMinutes 0 so files are eligible the moment they are written.
    #>
    param([string] $Id = 'eng', [int] $MaxDelete = 50)

    if (Test-Path $engineRoot) { Remove-Item -LiteralPath $engineRoot -Recurse -Force }
    $L = Join-Path $engineRoot 'local'
    $R = Join-Path $engineRoot 'remote'
    $S = Join-Path $engineRoot 'state'
    New-Item -ItemType Directory -Path $L, $R, $S -Force | Out-Null

    return [pscustomobject]@{
        Link = [pscustomobject]@{
            Id = $Id; LocalPath = $L; RemotePath = $R; Provider = 'Plain'
            Seed = 'Local'; SettleMinutes = 0; MaxDelete = $MaxDelete
            Dehydrate = $false; HydrateBeforeDelete = $false
            Enabled = $true; Seeded = $true; LastRun = $null; LastResult = $null
        }
        Local = $L; Remote = $R; State = $S
    }
}

function Set-TestFile {
    param([string] $Path, [string] $Content, [datetime] $WriteUtc)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding utf8 -NoNewline
    if ($WriteUtc) { (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $WriteUtc }
    return (Get-Item -LiteralPath $Path)
}

function Write-TestManifest {
    param([object] $Ctx, [object[]] $Entries)
    Write-Manifest -Path (Get-ManifestPath -LinkId $Ctx.Link.Id -StateRoot $Ctx.State) -Entries $Entries
}

function Get-Action {
    param([object] $Ctx, [string] $RelPath)
    $items = Compare-LinkState -Link $Ctx.Link -ExcludePatterns @() -StateRoot $Ctx.State
    $hit = $items | Where-Object { $_.RelPath -eq $RelPath }
    if ($hit) { return $hit.Action }
    return '<absent>'
}

# --- new on one side, no history ---
$ctx = New-TestLink
$null = Set-TestFile (Join-Path $ctx.Local 'a.txt') 'hello'
Assert-Equal (Get-Action $ctx 'a.txt') 'CopyToRemote' "New local file classifies as CopyToRemote"

$ctx = New-TestLink
$null = Set-TestFile (Join-Path $ctx.Remote 'a.txt') 'hello'
Assert-Equal (Get-Action $ctx 'a.txt') 'CopyToLocal' "New remote file classifies as CopyToLocal"

# --- present both sides, identical, no history: adopt rather than conflict ---
$ctx = New-TestLink
$when = (Get-Date).ToUniversalTime().AddHours(-1)
$null = Set-TestFile (Join-Path $ctx.Local  'a.txt') 'same' $when
$null = Set-TestFile (Join-Path $ctx.Remote 'a.txt') 'same' $when
Assert-Equal (Get-Action $ctx 'a.txt') 'InSync' "Identical files with no manifest are adopted as InSync"

# --- present both sides, differing, no history: genuine disagreement ---
$ctx = New-TestLink
$null = Set-TestFile (Join-Path $ctx.Local  'a.txt') 'left'  $when
$null = Set-TestFile (Join-Path $ctx.Remote 'a.txt') 'right' $when.AddMinutes(5)
Assert-Equal (Get-Action $ctx 'a.txt') 'Conflict' "Differing files with no manifest classify as Conflict"

# --- changed on both sides since the manifest ---
$ctx = New-TestLink
$lf = Set-TestFile (Join-Path $ctx.Local  'a.txt') 'local-new'  $when.AddMinutes(10)
$rf = Set-TestFile (Join-Path $ctx.Remote 'a.txt') 'remote-new' $when.AddMinutes(20)
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'a.txt'
    LocalLength = 3; LocalWriteUtc = $when
    OdLength    = 3; OdWriteUtc    = $when
})
Assert-Equal (Get-Action $ctx 'a.txt') 'Conflict' "Both sides changed since manifest classifies as Conflict"

# --- deleted locally, remote unchanged: DeleteRemote (the 2026-08-07 regression) ---
$ctx = New-TestLink
$rf = Set-TestFile (Join-Path $ctx.Remote 'a.txt') 'kept' $when
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'a.txt'
    LocalLength = $rf.Length; LocalWriteUtc = $rf.LastWriteTimeUtc
    OdLength    = $rf.Length; OdWriteUtc    = $rf.LastWriteTimeUtc
})
Assert-Equal (Get-Action $ctx 'a.txt') 'DeleteRemote' "Deleted locally + remote unchanged classifies as DeleteRemote"

# and it must actually apply, with a real path -- this is the exact failure that
# reached production: a renamed property left $null bound to -Path.
$res = Invoke-LinkSync -Link $ctx.Link -ExcludePatterns @() -StateRoot $ctx.State
Assert-Equal $res.Failed 0 "DeleteRemote applies without a parameter-binding failure"
Assert-Equal $res.Deleted 1 "DeleteRemote removed exactly one file"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $ctx.Remote 'a.txt'))) "Remote file is gone after DeleteRemote"

# --- deleted remotely, local unchanged: DeleteLocal ---
$ctx = New-TestLink
$lf = Set-TestFile (Join-Path $ctx.Local 'a.txt') 'kept' $when
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'a.txt'
    LocalLength = $lf.Length; LocalWriteUtc = $lf.LastWriteTimeUtc
    OdLength    = $lf.Length; OdWriteUtc    = $lf.LastWriteTimeUtc
})
Assert-Equal (Get-Action $ctx 'a.txt') 'DeleteLocal' "Deleted remotely + local unchanged classifies as DeleteLocal"

# --- deleted remotely but edited locally: the edit wins, nothing is destroyed ---
$ctx = New-TestLink
$lf = Set-TestFile (Join-Path $ctx.Local 'a.txt') 'edited since' $when.AddMinutes(30)
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'a.txt'
    LocalLength = 4; LocalWriteUtc = $when
    OdLength    = 4; OdWriteUtc    = $when
})
Assert-Equal (Get-Action $ctx 'a.txt') 'CopyToRemote' "Deleted remotely but edited locally keeps the local edit"

# --- gone from both sides but still in the manifest ---
$ctx = New-TestLink
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'a.txt'
    LocalLength = 4; LocalWriteUtc = $when
    OdLength    = 4; OdWriteUtc    = $when
})
Assert-Equal (Get-Action $ctx 'a.txt') 'Forget' "Absent from both sides classifies as Forget"

# --- exclude patterns are honoured ---
$ctx = New-TestLink
$null = Set-TestFile (Join-Path $ctx.Local '~$book.xlsx') 'lock'
$excluded = Compare-LinkState -Link $ctx.Link -ExcludePatterns @('~$*') -StateRoot $ctx.State
Assert-Equal @($excluded).Count 0 "Excluded file is not classified at all"

# ------------------------------------------------- 7. MaxDelete abort gate ---
Write-Host "7. Testing MaxDelete abort (lib/Actions.ps1)" -ForegroundColor Yellow

$ctx = New-TestLink -MaxDelete 2
$entries = @()
foreach ($n in 1..5) {
    $f = Set-TestFile (Join-Path $ctx.Remote "f$n.txt") "content$n" $when
    $entries += [pscustomobject]@{
        RelPath = "f$n.txt"
        LocalLength = $f.Length; LocalWriteUtc = $f.LastWriteTimeUtc
        OdLength    = $f.Length; OdWriteUtc    = $f.LastWriteTimeUtc
    }
}
Write-TestManifest $ctx $entries

$res = Invoke-LinkSync -Link $ctx.Link -ExcludePatterns @() -StateRoot $ctx.State
Assert-True $res.Aborted "5 deletions against MaxDelete 2 aborts the pass"
Assert-Equal $res.Deleted 0 "Aborted pass deleted nothing"
Assert-Equal @(Get-ChildItem -LiteralPath $ctx.Remote -File).Count 5 "All 5 files still on disk after the abort"

# The cap must be a whole-pass gate, not a per-file one: exactly at the limit
# it proceeds.
$ctx2 = New-TestLink -MaxDelete 5
$entries2 = @()
foreach ($n in 1..5) {
    $f = Set-TestFile (Join-Path $ctx2.Remote "f$n.txt") "content$n" $when
    $entries2 += [pscustomobject]@{
        RelPath = "f$n.txt"
        LocalLength = $f.Length; LocalWriteUtc = $f.LastWriteTimeUtc
        OdLength    = $f.Length; OdWriteUtc    = $f.LastWriteTimeUtc
    }
}
Write-TestManifest $ctx2 $entries2
$res2 = Invoke-LinkSync -Link $ctx2.Link -ExcludePatterns @() -StateRoot $ctx2.State
Assert-True (-not $res2.Aborted) "Exactly MaxDelete deletions is allowed to proceed"
Assert-Equal $res2.Deleted 5 "All 5 deletions applied at the limit"

# ----------------------------------------------------- 8. Conflict forking ---
Write-Host "8. Testing conflict fork keeps both versions" -ForegroundColor Yellow

$ctx = New-TestLink
$null = Set-TestFile (Join-Path $ctx.Local  'doc.txt') 'LOCAL VERSION'  $when.AddMinutes(10)
$null = Set-TestFile (Join-Path $ctx.Remote 'doc.txt') 'REMOTE VERSION' $when.AddMinutes(20)
Write-TestManifest $ctx @([pscustomobject]@{
    RelPath = 'doc.txt'
    LocalLength = 3; LocalWriteUtc = $when
    OdLength    = 3; OdWriteUtc    = $when
})

$res = Invoke-LinkSync -Link $ctx.Link -ExcludePatterns @() -StateRoot $ctx.State
Assert-Equal $res.Conflicts 1 "Conflict was forked, not resolved"

$forks = @(Get-ChildItem -LiteralPath $ctx.Local -File | Where-Object { $_.Name -like '*conflict*' })
Assert-Equal $forks.Count 1 "A conflict copy was written beside the local file"
if ($forks.Count -eq 1) {
    Assert-Equal (Get-Content -LiteralPath $forks[0].FullName -Raw) 'REMOTE VERSION' "Conflict copy holds the remote version"
}
Assert-Equal (Get-Content -LiteralPath (Join-Path $ctx.Local 'doc.txt') -Raw) 'LOCAL VERSION' "Local file still holds the local version"
Assert-Equal (Get-Content -LiteralPath (Join-Path $ctx.Remote 'doc.txt') -Raw) 'LOCAL VERSION' "Remote side now carries the local version"

# --------------------------------------------------- 9. Manifest round-trip ---
Write-Host "9. Testing manifest serialisation (lib/Manifest.ps1)" -ForegroundColor Yellow

$mfPath = Join-Path $testDir 'test-manifest.json'
if (Test-Path $mfPath) { Remove-Item -LiteralPath $mfPath -Force }

# Empty must serialise as [] and read back as nothing -- not as null, and not as
# a file the next pass reads as "everything is new".
Write-Manifest -Path $mfPath -Entries @()
Assert-Equal (Get-Content -LiteralPath $mfPath -Raw).Trim() '[]' "Empty manifest serialises as []"
Assert-Equal (Read-Manifest -Path $mfPath).Count 0 "Empty manifest reads back as zero entries"

# A single entry must not collapse into a bare object that reloads wrongly.
$stamp = [datetime]::SpecifyKind((Get-Date '2026-01-02 03:04:05'), 'Utc')
Write-Manifest -Path $mfPath -Entries @([pscustomobject]@{
    RelPath = 'one.txt'; LocalLength = 11; LocalWriteUtc = $stamp
    OdLength = 11;       OdWriteUtc  = $stamp
})
$back = Read-Manifest -Path $mfPath
Assert-Equal $back.Count 1 "Single-entry manifest reads back as one entry"
Assert-Equal $back['one.txt'].LocalLength 11 "Round-tripped length survives"
Assert-Equal $back['one.txt'].LocalWriteUtc.ToUniversalTime().ToString('s') $stamp.ToString('s') "Round-tripped timestamp survives"

# Two entries, and lookup is case-insensitive on the key.
Write-Manifest -Path $mfPath -Entries @(
    [pscustomobject]@{ RelPath = 'Sub\Two.txt'; LocalLength = 1; LocalWriteUtc = $stamp; OdLength = 1; OdWriteUtc = $stamp }
    [pscustomobject]@{ RelPath = 'three.txt';   LocalLength = 2; LocalWriteUtc = $stamp; OdLength = 2; OdWriteUtc = $stamp }
)
$back2 = Read-Manifest -Path $mfPath
Assert-Equal $back2.Count 2 "Two-entry manifest reads back as two entries"
Assert-True ($null -ne $back2['sub\two.txt']) "Manifest keys are lower-cased for lookup"

if (Test-Path $mfPath) { Remove-Item -LiteralPath $mfPath -Force }

# ------------------------------------------------------- 10. Availability ---
# An unmounted drive, a deleted folder and a stopped cloud client all look like
# "path missing" to Test-Path, but need different things done about them.
Write-Host "10. Testing availability reporting (lib/Availability.ps1)" -ForegroundColor Yellow

# Pick a drive letter that definitely is not mounted.
# 90..82 is 'Z' down to 'R'. A string range ('Z'..'R') is an integer range in
# PowerShell and throws on the cast.
$freeLetter = $null
foreach ($code in 90..82) {
    $c = [char]$code
    if (-not (Test-Path -LiteralPath ("{0}:\" -f $c))) { $freeLetter = $c; break }
}

$ctx = New-TestLink
Assert-Equal (Get-LinkAvailability -Link $ctx.Link).State 'Ready' "Both folders present reports Ready"
Assert-True (Get-LinkAvailability -Link $ctx.Link).Ok "Ready link is Ok to sync"

if ($freeLetter) {
    $offline = $ctx.Link.PSObject.Copy()
    $offline.RemotePath = "{0}:\SomeFolder" -f $freeLetter
    $a = Get-LinkAvailability -Link $offline
    Assert-Equal $a.State 'DriveOffline' "Unmounted drive reports DriveOffline, not FolderMissing"
    Assert-True $a.Blocking "DriveOffline blocks the pass"
    Assert-True ($a.Summary -match [regex]::Escape("$freeLetter" + ':')) "DriveOffline summary names the drive"
}
else {
    Write-Host "  [SKIP] no unmounted drive letter available to test DriveOffline" -ForegroundColor DarkYellow
}

# Drive mounted, folder gone -- a different diagnosis from the same Test-Path result.
$gone = $ctx.Link.PSObject.Copy()
$gone.RemotePath = Join-Path $ctx.Remote 'no-such-subfolder'
$a2 = Get-LinkAvailability -Link $gone
Assert-Equal $a2.State 'FolderMissing' "Missing folder on a mounted drive reports FolderMissing"
Assert-True $a2.Blocking "FolderMissing blocks the pass"

# No remote configured at all.
$noRemote = $ctx.Link.PSObject.Copy()
$noRemote.RemotePath = $null
Assert-Equal (Get-LinkAvailability -Link $noRemote).State 'NoRemote' "Link with no remote path reports NoRemote"

# A blocked link must abort cleanly rather than throwing, and touch nothing.
$null = Set-TestFile (Join-Path $ctx.Local 'keepme.txt') 'data'
$blockedRes = Invoke-LinkSync -Link $gone -ExcludePatterns @() -StateRoot $ctx.State
Assert-True $blockedRes.Aborted "Unavailable link aborts the pass"
Assert-Equal $blockedRes.State 'FolderMissing' "Abort result carries the availability state"
Assert-Equal $blockedRes.Deleted 0 "Unavailable link deletes nothing"
Assert-True (Test-Path -LiteralPath (Join-Path $ctx.Local 'keepme.txt')) "Local file untouched when the link is unavailable"

# Drive detection itself.
Assert-True (Test-DriveMounted -Path $ctx.Local) "Test-DriveMounted true for a real path"
if ($freeLetter) {
    Assert-True (-not (Test-DriveMounted -Path ("{0}:\anything" -f $freeLetter))) "Test-DriveMounted false for an unmounted letter"
}

# "I cannot tell" must not be reported as "not running".
Assert-True ($null -eq (Test-CloudClientRunning -ProviderLabel 'Folder')) "Unknown provider returns null, not false"
$odState = Test-CloudClientRunning -ProviderLabel 'OneDrive'
Assert-True (($odState -eq $true) -or ($odState -eq $false)) "Known provider returns a definite true/false"

if (Test-Path $engineRoot) { Remove-Item -LiteralPath $engineRoot -Recurse -Force -ErrorAction SilentlyContinue }

# Summary
Write-Host ''
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Test Results: $script:Passed Passed, $script:Failed Failed" -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "=========================================" -ForegroundColor Cyan

if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
