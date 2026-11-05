# Read-only dashboard inventories run outside the Windows Forms thread.
function Start-DashboardScan {
    param([string] $Root, [object[]] $Links, [string] $StateRoot)
    $registryJson = ConvertTo-Json -InputObject @($Links) -Depth 8 -Compress
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript({
        param($Root, $RegistryJson, $StateRoot)
        $ErrorActionPreference = 'Stop'
        foreach ($module in @('Provider', 'Availability', 'Settle', 'Manifest', 'Conflicts')) {
            . (Join-Path $Root "lib\$module.ps1")
        }
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
                Id = $link.Id; Availability = $null; Copies = @(); Deletions = @(); Error = ''
            }
            try {
                $entry.Availability = Get-LinkAvailability -Link $link
                if (-not $entry.Availability.Blocking) {
                    $entry.Copies = @(Get-LinkConflictCopies -Link $link)
                    $entry.Deletions = @(Get-LinkDeletionConflicts -Link $link -StateRoot $StateRoot -ExcludePatterns $patterns)
                }
            }
            catch { $entry.Error = $_.Exception.Message }
            $entry
        }
    }).AddArgument($Root).AddArgument($registryJson).AddArgument($StateRoot)
    try {
        $handle = $worker.BeginInvoke()
        return [pscustomobject]@{ Worker = $worker; Handle = $handle; RegistryJson = $registryJson }
    }
    catch { $worker.Dispose(); throw }
}
