# Read-only dashboard inventories run outside the Windows Forms thread.

function Get-SavedPassInventory {
    <#
        Duplicate and deletion-conflict lists that the last sync already made,
        for each link synced within the last MaxAgeMinutes.

        Every pass lists both for every link it compares and saves them in the
        pass summary. Re-walking every folder when the dashboard opens repeats
        that work (about 20 s across the links on 2026-11-05). A link is used
        only when the summary was written after the link's own last run, that
        run compared the folders in full (its message starts with "applied"),
        and the link is seeded. Anything else gets a live scan, as before.
    #>
    param(
        [object[]] $Links,
        [object]   $Summary,
        [int]      $MaxAgeMinutes = 10,
        [datetime] $Now = (Get-Date)
    )
    $saved = @{}
    if (-not $Summary -or -not $Summary.PSObject.Properties['PerLink']) { return $saved }
    $format = 'yyyy-MM-dd HH:mm:ss'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $written = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Summary.When, $format, $culture, 'None', [ref]$written)) { return $saved }
    foreach ($link in @($Links)) {
        if (-not $link -or -not $link.Seeded -or -not $link.LastRun) { continue }
        $lastRun = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$link.LastRun, $format, $culture, 'None', [ref]$lastRun)) { continue }
        if ($written -lt $lastRun) { continue }
        if (($Now - $lastRun).TotalMinutes -gt $MaxAgeMinutes -or $lastRun -gt $Now) { continue }
        $entry = @($Summary.PerLink | Where-Object { $_.LinkId -eq $link.Id }) | Select-Object -First 1
        if (-not $entry -or $entry.Aborted -or ([string]$entry.Message) -notlike 'applied *') { continue }
        $saved[$link.Id] = [pscustomobject]@{
            Copies    = @($entry.ConflictCopies | Where-Object { $_ })
            Deletions = @($entry.DeletionConflicts | Where-Object { $_ })
            When      = [string]$link.LastRun
        }
    }
    return $saved
}

function Start-DashboardScan {
    param([string] $Root, [object[]] $Links, [string] $StateRoot, [hashtable] $Saved = @{})
    $registryJson = ConvertTo-Json -InputObject @($Links) -Depth 8 -Compress
    $savedJson = ConvertTo-Json -InputObject $Saved -Depth 8 -Compress
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript({
        param($Root, $RegistryJson, $StateRoot, $SavedJson)
        $ErrorActionPreference = 'Stop'
        foreach ($module in @('Provider', 'Availability', 'Settle', 'Manifest', 'Conflicts')) {
            . (Join-Path $Root "lib\$module.ps1")
        }
        $saved = ConvertFrom-Json -InputObject $SavedJson
        # Same handling as the CLI: a missing excludes file means no patterns,
        # not a failed inventory for every link.
        $excludesFile = Join-Path $Root 'config\excludes.txt'
        $patterns = @()
        if (Test-Path -LiteralPath $excludesFile) {
            $patterns = @(Get-Content -LiteralPath $excludesFile |
                Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() } |
                Where-Object { $_ })
        }
        foreach ($link in (ConvertFrom-Json -InputObject $RegistryJson)) {
            $entry = [pscustomobject]@{
                Id = $link.Id; Availability = $null; Copies = @(); Deletions = @(); Error = ''; SavedFrom = ''
            }
            try {
                # Availability is always checked live: it is quick, and a drive
                # unplugged since the last sync must show at once.
                $entry.Availability = Get-LinkAvailability -Link $link
                if (-not $entry.Availability.Blocking) {
                    $prior = if ($saved) { $saved.PSObject.Properties[[string]$link.Id] } else { $null }
                    if ($prior) {
                        $entry.Copies = @($prior.Value.Copies | Where-Object { $_ })
                        $entry.Deletions = @($prior.Value.Deletions | Where-Object { $_ })
                        $entry.SavedFrom = [string]$prior.Value.When
                    }
                    else {
                        $entry.Copies = @(Get-LinkConflictCopies -Link $link)
                        $entry.Deletions = @(Get-LinkDeletionConflicts -Link $link -StateRoot $StateRoot -ExcludePatterns $patterns)
                    }
                }
            }
            catch { $entry.Error = $_.Exception.Message }
            $entry
        }
    }).AddArgument($Root).AddArgument($registryJson).AddArgument($StateRoot).AddArgument($savedJson)
    try {
        $handle = $worker.BeginInvoke()
        return [pscustomobject]@{ Worker = $worker; Handle = $handle; RegistryJson = $registryJson }
    }
    catch { $worker.Dispose(); throw }
}
