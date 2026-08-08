<#
    Logging.ps1  --  shared logging for DriveRelay.

    Extracted from OneDriveGate.ps1 so both it and DriveRelay.ps1 write the same
    line format and share the same rotation behaviour.

    Logging must never take a caller down: every failure here is swallowed.
#>

# Set by the caller before first use; each component keeps its own log.
$script:DefaultRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$script:LogPath     = Join-Path $script:DefaultRoot 'driverelay.log'

function Set-LogPath {
    param([Parameter(Mandatory)][string] $Path)
    $script:LogPath = $Path
}

function Get-LogPath { return $script:LogPath }

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line

    try {
        $dir = Split-Path -Parent $script:LogPath
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # Keep the log from growing without bound: trim to the last 2000 lines at 1 MB.
        if (Test-Path $script:LogPath) {
            if ((Get-Item $script:LogPath).Length -gt 1MB) {
                $tail = Get-Content $script:LogPath -Tail 2000
                Set-Content -Path $script:LogPath -Value $tail -Encoding utf8
            }
        }

        Add-Content -Path $script:LogPath -Value $line -Encoding utf8
    }
    catch {
        # Logging must never take the caller down.
    }
}
