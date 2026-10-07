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
| Gone remotely, local unchanged since manifest | `DeleteLocal` |
| Gone locally, remote unchanged since manifest | `DeleteRemote` |
| Gone remotely but **edited** locally | `CopyToRemote` — your edit outranks the delete |
| Gone locally but **edited** remotely | `CopyToLocal` — the edit outranks the delete |
| Changed on both sides | `Conflict` — keep both |
| Both sides present, identical, no history | `InSync`, adopted into the manifest |
| Both sides present, differ, no history | `Conflict` |
| In manifest, gone from both sides | `Forget` |

**Absence alone never causes a delete.** A delete is only proposed when the manifest proves the
file existed at the last pass.

## Conflicts

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
- **Recoverable deletes.** Recycle Bin where there is content to store; otherwise the cloud
  service's online recycle bin, and the log says which applies. `HydrateBeforeDelete` downloads
  first so the Recycle Bin keeps a real copy.
- **Delete cap.** A pass proposing more deletions than `MaxDelete` aborts entirely rather than
  applying half of them.
- **Honest manifest commits.** Only paths whose action actually succeeded are recorded. A
  deferred or failed file keeps its previous entry, so the next pass compares against the same
  baseline instead of mistaking the divergence for a fresh conflict.
- **One pass at a time.** A named mutex plus the scheduler's own guard. Two passes copying the
  same file in opposite directions is the failure this prevents.
- **Stale baselines set aside.** Re-registering a link whose id already has a manifest moves
  that manifest aside — a baseline for different folders becomes wrong deletions.

## Components

```
DriveRelay.ps1      CLI and engine entry: add, rm, list, check, sync, status, etc.
DriveRelayTray.ps1  tray agent; runs passes on a timer, shows state
DriveRelayUI.ps1    modernized dashboard window
DriveRelayTray.vbs  hidden launcher (generated by Install.ps1)
Install.ps1         icons, launcher, Start Menu and Startup shortcuts
Uninstall.ps1       reverses the above; keeps links unless told otherwise

lib\Logging.ps1     Write-Log, shared, size-capped
lib\Provider.ps1    remote path resolution and provider detection
lib\Icons.ps1       the artwork, drawn in code
lib\Registry.ps1    links.json
lib\Manifest.ps1    snapshots, manifest, diff, readiness
lib\Settle.ps1      lock and quiescence tests
lib\Hydration.ps1   placeholder control
lib\Actions.ps1     copy, delete, conflict fork, seed, the pass itself
lib\Pass.ps1        single-instance pass runner shared by CLI, tray and scheduler
tools\New-Icons.ps1 writes the .ico files
```

The tray, the CLI and the scheduled task all call `Invoke-SyncPass`. There is no behaviour that
exists in one and not the others.

## Two PowerShell 5.1 traps worth knowing

Both bit repeatedly during development and are commented at each site:

- **Array unrolling.** `return $bytes` on a `byte[]` flattens into the caller's array;
  `ConvertTo-Json` via the pipeline unrolls; `ConvertFrom-Json` piped inside `@()` can leave the
  whole array as one element. Use `-InputObject` and a leading comma.
- **`System.Drawing` cannot decode PNG frames in an `.ico`.** Explorer can. So a PNG-framed icon
  looks right on the desktop and like noise in the tray. Frames are written as DIB.
