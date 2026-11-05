# Architecture

## The shape of it

Both sides of every link are **ordinary filesystem paths**. The orchestrator is a folder-pair
mirroring tool. It has no cloud credentials, makes no network calls, and knows nothing about
any cloud service beyond a pair of file attributes. Cloud transfer stays entirely the desktop
client's job.

```
D:\Office        <->  D:\OneDrive\Office        -> OneDrive client uploads
D:\Work\Foo      <->  G:\My Drive\Foo           -> Google Drive client uploads
D:\Work\Bar      <->  \\nas\backup\Bar          -> nothing to upload; it is just a copy
```

Only registered pairs are ever touched. Everything else in the cloud folder is outside the
tool's concern.

## Providers

Only one behaviour is provider-specific: turning a synced file back into a placeholder to free
disk space.

| Provider | Meaning |
|---|---|
| `Plain` | No placeholder handling. Google Drive Mirror mode, Dropbox, a network share, another disk, a USB drive. |
| `CloudFiles` | Windows Cloud Files placeholders via the PINNED / UNPINNED attributes. Measured working with OneDrive. |
| `Auto` | Inspect the folder and decide. The default. |

Detection looks for a file carrying Offline, RecallOnDataAccess, PINNED or UNPINNED, or a
directory that is a reparse point — how cloud providers project their namespace. Only a sample
is examined; walking 170,000 files to answer a yes/no question is not worth the wait.

Getting it wrong is cheap in the safe direction: a cloud folder mistaken for `Plain` simply
keeps its files on disk instead of freeing them. Nothing is copied wrongly either way.

**Not verified:** Google Drive Stream mode uses the same Windows Cloud Files API and is
expected to behave like OneDrive, but Google Drive is not installed on this machine so that is
an expectation, not a measurement.

## The constraint that shapes everything

**A cloud-backed remote side cannot be hashed.** Reading a placeholder's content downloads it.
So change detection uses **size and last-write-time only** — never `Get-FileHash`, never
anything that opens a file for read on the remote side. Enumeration reads metadata and is safe.

## The manifest

The manifest records both sides at the end of the last successful pass. Without it, presence
and absence are ambiguous:

> A file is here locally but missing remotely. Did you *create* it here, or *delete* it there?

Comparing two sides alone cannot answer that. Guessing wrong either resurrects files you
deleted or destroys files you just made. With the manifest the question becomes answerable:
*was it here last time?*

Stored per link at `state\<link-id>\manifest.json`. The field names use `Od` for the remote
side for historical reasons; renaming them would make existing manifests unreadable, which
would look like a folder full of new files.

## Classification

| Situation | Action |
|---|---|
| New or changed locally | `CopyToRemote` |
| New or changed remotely | `CopyToLocal` |
| Unchanged tracked NTFS file moved locally | `MoveRemote` |
| Unchanged tracked NTFS file moved remotely | `MoveLocal` |
| Gone remotely, local unchanged since manifest | `DeleteLocal` |
| Gone locally, remote unchanged since manifest | `DeleteRemote` |
| Gone remotely but local metadata changed | `DeletionConflict` — preserve the local copy and leave the remote deletion intact; review required |
| Gone locally but remote metadata changed | `DeletionConflict` — preserve the remote copy and leave the local deletion intact; review required |
| Changed on both sides | `Conflict` — keep both |
| Both sides present, identical, no history | `InSync`, adopted into the manifest |
| Both sides present, differ, no history | `Conflict` |
| In manifest, gone from both sides | `Forget` |

**Absence alone never causes a delete.** A delete is only proposed when the manifest proves the
file existed at the last pass.

## Moves and renames

Snapshots and manifests include optional `LocalFileId` / `OdFileId` fields.
`lib/FileIdentity.ps1` uses a zero-access, shared Windows metadata handle with
`OPEN_REPARSE_POINT` to query volume serial, NTFS file index and creation time.
It never reads placeholder contents. Hard-linked files and unsupported or
unavailable identities return no ID. Old manifests remain readable; successful
ordinary actions and `InSync` adoption fill in IDs on the next pass.

After ordinary classification, a `DeleteRemote` plus a new `CopyToRemote` becomes
one `MoveRemote` only if the moving side has the same unique ID as its old
manifest entry, both sides still match their own saved metadata, and the
counterpart retains its saved ID. The reverse produces `MoveLocal`. The old
delete is removed from the plan before checking `MaxDelete`. No filename or
size/time heuristic substitutes for identity. Moves with edits, legacy baselines
or unsupported identities retain the ordinary classification rules.

Execution gates both files for settling and locks, then rechecks IDs, metadata,
the old path's absence on the originating side, destination absence and the
planned existing parent. The Windows rename uses neither `REPLACE_EXISTING` nor
`COPY_ALLOWED`: collisions and volume boundaries cannot overwrite or silently
turn into copies. Failed or deferred moves keep the old baseline; success drops
the old entry and records the new path and both IDs. Emptied counterpart folders
are pruned by the existing cleanup. Populated directory moves are individual
file moves; empty directories and case-only renames remain outside the model.

Windows API references: [CreateFile metadata access](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew),
[file identity](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle),
and [MoveFileEx flags](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw).

## Conflicts

Deletion conflicts do not fork or copy anything. Since remote content is never
hashed, a size or timestamp change is only evidence of a possible edit. The
previous manifest entry is retained, so the conflict remains visible on later
passes. CLI check/status list it; sync prints the surviving and deleted paths;
the dashboard shows a **Review** button with those paths and resolution guidance.
Dashboard availability and conflict inventories run in a background PowerShell
runspace (`lib/DashboardScan.ps1`). Cards initially say **Checking folders...**;
rendering never enumerates linked folders or compares manifests. A 250 ms UI
timer collects completed results and schedules another scan five seconds after
completion, with only one scan in flight. Results for a changed registry are
discarded. Closing the dashboard requests cancellation without waiting on disk.
Pass summaries retain `DeletionConflicts` for tray warnings. To keep the deletion,
delete the surviving copy; to keep the file, deliberately restore it on the
deleted side. New files without a manifest entry still copy normally.

Both versions are kept; nothing is merged and no winner is picked. The remote version is
brought down beside the local one under a name like
`Book1 (conflict from OneDrive 2026-08-07 151207).xlsx`, and the local file is pushed up as
current. The conflict copy has no manifest entry, so the next pass sees it as a new local file
and carries it across on its own.

`lib/Conflicts.ps1` recognizes existing copies by that timestamped naming format
on either side. It groups the same relative copy name across both folders, reports
the original name and actual copy paths, and never reads content. CLI `status` and
the dashboard's expandable **Duplicates** section list these copies live. Background passes
store `ConflictCopies` in `lastpass.json` so the tray continues warning after the
creation pass. Removing a copy clears it from the next scan; renamed copies no
longer match. This inventory does not change replication decisions.

## Settle model

A file is eligible only when it is **unlocked** and **unmodified for the settle window**
(default 3 minutes).

1. **Lock test** — attempt an exclusive-share open. Anything held by Excel, Tally or KDK is in
   use. A dehydrated placeholder is reported unlocked *without being opened*, because it has no
   local content for an application to hold, and opening it would trigger the download this
   design exists to avoid.
2. **Quiescence test** — `LastWriteTime` older than the settle window.

Gating is **per file**, so one open Tally company blocks only its own files, not the link.
Observed working on live data: with TallyPrime running, a pass deferred `TSTATE.TSF`,
`TUPDATE.TSF` and `VchStatus.1800` and copied everything else.

## Safety rules

- **Atomic copies.** Content goes to a `.tmp` name the snapshot excludes, then moves into
  place, so a half-copied file is never visible as complete.
- **Copies recheck destinations.** Planned copies record the destination metadata
  and nearest existing parent. Both are checked before copying and again before
  replacing the destination. A deletion or edit during a long pass defers the
  copy and leaves its baseline intact. Conflict forks use the same checks.
- **Recoverable deletes.** Recycle Bin where there is content to store; otherwise the cloud
  service's online recycle bin, and the log says which applies. `HydrateBeforeDelete` downloads
  first so the Recycle Bin keeps a real copy. Only fixed local volumes count as having a Recycle
  Bin (`Test-RecycleBinVolume`): on UNC paths, mapped network drives and removable media the
  file is renamed into `<side root>\.driverelay-deleted\<timestamp>\<relative path>`, which
  snapshots never list. A rename that cannot happen there defers the delete; nothing falls back
  to a permanent delete. A file held open is deferred rather than handed to the shell, which
  would otherwise show a blocking "file in use" dialog.
- **Complete listings only.** `Get-SideSnapshot` walks one folder at a time and throws on any
  enumeration error, so a folder that cannot be listed cannot make its files look deleted. Only
  the post-pass manifest refresh accepts a partial listing (`-AllowPartial`).
- **Links are not followed.** Junctions, mount points and directory symbolic links are skipped
  (cloud placeholder folders are reparse points too, but not links, and are walked).
  `Compare-LinkState` drops every path under a skipped link on either side, so no action is
  planned and the manifest entry is kept.
- **Deletes re-checked at apply time.** Every delete runs after every copy, so the target must
  still match its planned metadata and its counterpart must still be absent, or it is deferred.
- **Seeding keeps the replaced version.** A differing file on the non-seed side is renamed to a
  conflict copy before the seed side's version is copied in.
- **Delete cap.** A pass proposing more deletions than `MaxDelete` aborts entirely rather than
  applying half of them.
- **Honest manifest commits.** Only paths whose action actually succeeded are recorded. A
  deferred or failed file keeps its previous entry, so the next pass compares against the same
  baseline instead of mistaking the divergence for a fresh conflict. What is recorded is the
  version that was reconciled (`Get-CommittedEntry`): the source as planned, and the other side
  only if it still holds that version. An edit made during the pass therefore stays pending.
- **History is required.** Manifests are written to a flushed `.tmp` and swapped in with
  `File.Replace`, keeping the previous version as `.bak`. A seeded link whose manifest is
  missing, empty or unreadable is restored from an intact `.tmp`, then `.bak`
  (`Repair-LinkManifest`); with neither, the link stops. An older baseline is safe: paths it
  does not know read as new, never as deleted.
- **One pass at a time.** A named mutex plus the scheduler's own guard. Two passes copying the
  same file in opposite directions is the failure this prevents.
- **Stale baselines set aside.** Re-registering a link whose id already has history renames
  `state\<id>\` to `state\<id>.superseded-<timestamp>\` — manifest and `.bak`/`.tmp`
  together — because a baseline for a different registration becomes wrong deletions. It
  happens inside `Add-Link`, under the registry lock and before the link is saved, so no pass
  can see the new link with the old history; if the rename fails, nothing is registered. When
  there is history to move, `Add-Link` first takes the pass lock (pass lock before registry
  lock, the order a pass uses), so a still-running pass of the removed link cannot write the
  old manifest back. If a pass is running, the add is refused with a retry message.

## Components

```
DriveRelay.ps1      CLI and engine entry: add, rm, list, check, sync, status, etc.
DriveRelayTray.ps1  tray agent; runs passes on a timer, shows state
DriveRelayUI.ps1    modernized dashboard window
DriveRelay.exe      branded hidden launcher (built by Install.ps1)
DriveRelayTray.vbs  legacy hidden launcher for manual use
Install.ps1         icons, launcher, Start Menu and Startup shortcuts
Uninstall.ps1       reverses the above; keeps links unless told otherwise
Setup.cmd / Uninstall.cmd  double-clickable wrappers for the two scripts above
OneDriveGate.ps1    optional: keeps the OneDrive client stopped during working hours

lib\Logging.ps1     Write-Log, shared, severity-filtered, size/age retention
lib\LogViewer.ps1   read-only log window for tray/dashboard
lib\Availability.ps1 drive/folder/client availability classification
lib\Conflicts.ps1   conflict-copy and deletion-conflict inventories
lib\DashboardScan.ps1 background dashboard inventories
lib\Provider.ps1    remote path resolution and provider detection
lib\Icons.ps1       the artwork, drawn in code
lib\Registry.ps1    links.json
lib\Manifest.ps1    snapshots, manifest, diff, readiness
lib\FileIdentity.ps1 metadata-only NTFS identity and guarded native rename
lib\Settle.ps1      lock and quiescence tests
lib\Hydration.ps1   placeholder control
lib\Actions.ps1     copy, delete, conflict fork, seed, one link's pass (Invoke-LinkSync)
lib\Pass.ps1        single-instance pass runner shared by CLI, tray and scheduler
lib\Settings.ps1    settings.json: per-field validation, locked Update-AppSettings
lib\Startup.ps1     the Startup shortcut, shared by Install.ps1 and the dashboard
tools\New-Icons.ps1 writes the .ico files
tools\New-Launcher.ps1 builds DriveRelay.exe from DriveRelayLauncher.cs
tools\Clear-BuildOutput.ps1 removes the root build\ and dist\ folders, nothing else
```

The tray, the CLI and the scheduled task all call `Invoke-SyncPass`. There is no behaviour that
exists in one and not the others.

The launcher is a .NET Framework Windows executable with DriveRelay file description,
product name and icon. Startup and Start Menu shortcuts target it directly rather than
`wscript.exe`, giving Task Manager's Startup apps the app's identity. It resolves the tray
script beside itself and starts the Windows PowerShell host with `UseShellExecute = false`
and `CreateNoWindow = true`, then exits. The tray continues to run in PowerShell. The build
uses the compiler shipped with Windows; no separate SDK is required.

## Source installation and generated output

`Setup.cmd` invokes `Install.ps1` in the source folder. Setup persists startup
preferences, builds the branded launcher with the Windows .NET Framework
compiler and creates current-user Start Menu/Startup shortcuts. Shortcuts use
the source folder directly. No separate application payload is staged, no
Windows uninstall registration is created, and setup does not guard an active
pass. The operator must wait for passes to finish and close the tray/dashboard
before updating source. `Uninstall.cmd` / `Uninstall.ps1` reverse source setup;
runtime links and history remain unless their removal is explicitly requested.

Inno Setup packaging was withdrawn on 2026-10-26. Its builder, template,
configuration helper and installer verification script are removed. Prior
packages, checksums, inventories and logs under ignored `release/` are retained
as historical local evidence. Older changelog entries describe the packaging
that existed then; they are not current build instructions.

`tools/Clear-BuildOutput.ps1` accepts only `build` and `dist` at the repository
root, checks their ancestors and descendants for links, and validates every
requested tree before deleting any. It never removes `release/`, source,
configuration or sync history. `tests/Test-BuildCleanup.ps1` exercises it in a
disposable fixture, including a real junction. Clear stale generated output
before builds and remove temporary output after successful checks and its
consumers finish. The root launcher used by source setup is a runtime artifact
and stays in place.

## Two PowerShell 5.1 traps worth knowing

Both bit repeatedly during development and are commented at each site:

- **Array unrolling.** `return $bytes` on a `byte[]` flattens into the caller's array;
  `ConvertTo-Json` via the pipeline unrolls; `ConvertFrom-Json` piped inside `@()` can leave the
  whole array as one element. Use `-InputObject` and a leading comma.
- **`System.Drawing` cannot decode PNG frames in an `.ico`.** Explorer can. So a PNG-framed icon
  looks right on the desktop and like noise in the tray. Frames are written as DIB.
