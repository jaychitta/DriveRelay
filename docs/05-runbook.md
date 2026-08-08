# Runbook

Procedures for the things that carry risk.

## Migrating a folder out of the sync root

Do one folder at a time and watch it for a few days before adding the next.

**1. Check the cost first.** Cloud-only files must be downloaded before they can be copied.

```powershell
$p = 'D:\OneDrive\Foo'
$f = Get-ChildItem $p -Recurse -File -Force
$off = @($f | Where-Object { ([int]$_.Attributes) -band 0x1000 })
'{0} files, {1} GB total, {2} GB to download' -f $f.Count,
    [math]::Round(($f|Measure-Object Length -Sum).Sum/1GB,2),
    [math]::Round(($off|Measure-Object Length -Sum).Sum/1GB,2)
```

If the download figure is large, expect the first pass to take hours and to need that much free
space temporarily.

**2. Create the destination and register the link.**

```powershell
New-Item -ItemType Directory -Force -Path 'D:\Foo'
.\DriveRelay.ps1 add -Local 'D:\Foo' -Remote 'D:\OneDrive\Foo' -Seed Remote -HydrateBeforeDelete
```

`-Seed Remote` means the cloud side is authoritative for the first pass. Use `-Seed Local` only
when the local folder already holds the good copy.

**3. Look before you leap.**

```powershell
.\DriveRelay.ps1 check -Id Foo -Detailed
```

Everything should be `CopyToLocal`. Anything else means the folders are not what you think.

**4. Seed it.** Large folders take a while; the tray or `-WhatIf` first if unsure.

```powershell
.\DriveRelay.ps1 sync -Id Foo
```

**5. Verify before trusting it.**

```powershell
$a = (Get-ChildItem 'D:\Foo' -Recurse -File -Force | Measure-Object Length -Sum)
$b = (Get-ChildItem 'D:\OneDrive\Foo' -Recurse -File -Force | Measure-Object Length -Sum)
'local {0} files {1} GB | remote {2} files {3} GB' -f $a.Count,
   [math]::Round($a.Sum/1GB,2), $b.Count, [math]::Round($b.Sum/1GB,2)
```

Counts and sizes should match. Zero-length files in the copy are fine **if** the same count
exists at source — check before assuming a failure.

**6. Repoint your applications** at the new local path. Until you do, you get no speed benefit.
Both copies stay live and linked, so you can switch gradually.

## Repointing Tally

Tally holds company files open. Do this with Tally closed.

1. Close TallyPrime completely, including any gateway or scheduler service still running.
2. Run a final `sync -Id Tally-Prime` so the local copy is current.
3. In Tally, change the data directory to `D:\Tally Prime`.
4. Open a company and confirm it loads and saves.
5. Leave the old path alone for a week. Once you are confident, it is just a synced backup.

**Do not** work in both locations at once. Both are linked, so edits in either will propagate,
but a company open in one while the orchestrator copies the other is exactly the situation the
settle window exists to avoid — do not test its limits with live accounts.

## Recovering a file

**Deleted by mistake, had content locally.** Recycle Bin.

**Deleted by mistake, was cloud-only.** The cloud service's online recycle bin — onedrive.com or
drive.google.com. Not this PC's. Enable `HydrateBeforeDelete` on that link so it does not happen
again.

**Wrong version won.** It did not — conflicts keep both. Look for
`<name> (conflict from <drive> <timestamp>)<ext>` beside the file.

**Everything looks deleted.** Stop. Do not run another pass. This is what the delete cap is for:
if more than `MaxDelete` files vanish, the pass aborts untouched. The usual cause is a remote
folder that is not mounted — check the path exists and is populated before syncing again.

## Rolling back a link

Unregistering never deletes files.

```powershell
.\DriveRelay.ps1 rm -Id Foo
```

Both folders keep everything. To also discard the sync history, delete `state\Foo\`. Note that
re-registering later starts from no baseline, so the first pass treats every file as new — that
is safe (it copies rather than deletes) but it will be a big pass.

## Changing the settle window

Three minutes suits most work. Raise it if files are being copied while an application is still
finishing with them; lower it if changes take too long to appear. Edit `SettleMinutes` in
`config\links.json` — per link, so Tally can be slower than documents.

## When a pass will not run

1. Is the tray running and not paused?
2. `driverelay.log` — a pass always logs something, even when idle.
3. Another pass may still be working; overlapping passes are skipped by design.
4. `status` will report a missing folder rather than treating it as mass deletion.

## Emergency stop

Tray > **Pause syncing**, or:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*DriveRelayTray.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Nothing is left half-done: copies are atomic, and a manifest is only committed for actions that
actually succeeded.
