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
        $patterns = @(Get-Content -LiteralPath (Join-Path $Root 'config\excludes.txt') |
            Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() })
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
