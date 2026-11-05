# Remove only fixed generated directories in this owning repository.
[CmdletBinding()]
param([string[]]$RelativePaths = @('build', 'dist'))
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$allowed = @('build', 'dist')
$targets = @()
foreach ($relative in $RelativePaths) {
    if ($relative -notin $allowed) { throw "Unrecognised generated folder: $relative" }
    $target = [IO.Path]::GetFullPath((Join-Path $projectRoot $relative))
    if (-not $target.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup escaped repository.' }
    $ancestor = $target
    while ($ancestor -and $ancestor.StartsWith($projectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $ancestor) {
            if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked cleanup path: $ancestor" }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($target)
    while ($pending.Count) {
        $item = Get-Item -LiteralPath $pending.Pop() -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked cleanup path: $($item.FullName)" }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $pending.Push($child.FullName) }
        }
    }
    $targets += $target
}
# Validate every target before the first removal.
foreach ($target in $targets) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }
