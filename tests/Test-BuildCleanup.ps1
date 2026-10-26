# Exercise destructive cleanup only in a disposable, repository-contained fixture.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $projectRoot ('build\cleanup-tests\' + [guid]::NewGuid().ToString('N'))
foreach ($path in @($projectRoot, (Join-Path $projectRoot 'build'), (Join-Path $projectRoot 'build\cleanup-tests'))) {
    if ((Test-Path -LiteralPath $path) -and
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Linked fixture ancestor: $path"
    }
}
New-Item -ItemType Directory -Path (Join-Path $fixture 'tools') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\Clear-BuildOutput.ps1') -Destination (Join-Path $fixture 'tools')
$cleanup = Join-Path $fixture 'tools\Clear-BuildOutput.ps1'
$passed = 0
function Assert-Cleanup([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Write-Fixture([string]$Relative) {
    $path = Join-Path $fixture $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -LiteralPath $path -Value 'preserve sentinel'
}
function Assert-Refused([string[]]$Paths) {
    $refused = $false
    try { & $cleanup -RelativePaths $Paths } catch { $refused = $true }
    Assert-Cleanup $refused ("Refuses unsafe request: " + ($Paths -join ', '))
}
try {
    foreach ($relative in @('build\nested\generated.txt','dist\generated.txt',
        'release\package.exe','config\links.json','state\baseline.json','source.ps1')) {
        Write-Fixture $relative
    }
    & $cleanup
    Assert-Cleanup (-not (Test-Path -LiteralPath (Join-Path $fixture 'build'))) 'Removes nested build output'
    Assert-Cleanup (-not (Test-Path -LiteralPath (Join-Path $fixture 'dist'))) 'Removes dist output'
    foreach ($relative in @('release\package.exe','config\links.json','state\baseline.json','source.ps1')) {
        Assert-Cleanup ((Get-Content -LiteralPath (Join-Path $fixture $relative)) -eq 'preserve sentinel') "Preserves $relative"
    }
    & $cleanup
    Assert-Cleanup $true 'Missing output folders are harmless'
    Write-Fixture 'build\generated.txt'
    foreach ($invalid in @('..\outside','release','android\build','build\..\config')) {
        Assert-Refused @('build',$invalid)
        Assert-Cleanup (Test-Path -LiteralPath (Join-Path $fixture 'build\generated.txt')) 'Valid target survives invalid batch'
    }
    New-Item -ItemType Directory -Path (Join-Path $fixture 'dist') | Out-Null
    & $cleanup -RelativePaths @('build')
    Assert-Cleanup (Test-Path -LiteralPath (Join-Path $fixture 'dist')) 'Subset cleanup preserves unrequested empty output'
    # A real junction proves validation completes before either target is deleted.
    Write-Fixture 'build\generated.txt'
    $junction = Join-Path $fixture 'dist\linked'
    New-Item -ItemType Junction -Path $junction -Target (Join-Path $fixture 'release') | Out-Null
    try {
        Assert-Refused @('build','dist')
        Assert-Cleanup (Test-Path -LiteralPath (Join-Path $fixture 'build\generated.txt')) 'Build survives a linked dist descendant'
        Assert-Cleanup (Test-Path -LiteralPath (Join-Path $fixture 'release\package.exe')) 'Junction target survives refusal'
    } finally { [IO.Directory]::Delete($junction) }
    & $cleanup
    Write-Host "Cleanup verification: $passed passed."
} finally {
    # Validate every entry and all ancestors before recursive fixture removal.
    $resolved = [IO.Path]::GetFullPath($fixture)
    $expectedParent = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\cleanup-tests'))
    if ((Split-Path -Parent $resolved) -ne $expectedParent) { throw 'Fixture cleanup escaped its test parent.' }
    $ancestor = $resolved
    while ($ancestor -and $ancestor.StartsWith($projectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-Path -LiteralPath $ancestor) -and
            ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked fixture cleanup: $ancestor" }
        $ancestor = Split-Path -Parent $ancestor
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($resolved)
    while ($pending.Count) {
        $item = Get-Item -LiteralPath $pending.Pop() -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked fixture cleanup: $($item.FullName)" }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $pending.Push($child.FullName) }
        }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
    foreach ($parent in @($expectedParent, (Join-Path $projectRoot 'build'))) {
        if ((Test-Path -LiteralPath $parent) -and -not (Get-ChildItem -LiteralPath $parent -Force | Select-Object -First 1)) {
            Remove-Item -LiteralPath $parent -Force
        }
    }
}
