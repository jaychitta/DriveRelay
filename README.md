# DriveRelay

Relays files between a fast local NTFS working folder and a cloud drive folder
(OneDrive, Google Drive, Dropbox, a network share, another disk) on Windows.

You work on plain NTFS at full speed. The cloud client still holds a copy and
keeps doing what it normally does. DriveRelay never talks to a network — it
copies between two ordinary folders, and the cloud client uploads from its side.

> **Concept and direction: Jayadheer Chitta. Implementation: Claude (Opus 5), Anthropic's
> model, in Claude Code.** The problem, the design calls and the standard for what
> counts as safe are Jayadheer's; the code that implements them was written by AI.
> See [Authorship](#authorship).

---

## Why

Some applications are miserable on a cloud-synced folder. Tally Prime, Access
databases and large Excel workbooks all hold files open, write in place, and hate
having a sync client reach in mid-write. Placeholder ("Files On-Demand") folders
make it worse: opening a file can block on a download.

DriveRelay lets those applications live on a normal local folder and moves the
changes across on a schedule, only when a file has been quiet long enough to be
safe to touch.

## Safety model

This tool moves and deletes real files, so the rules are worth stating plainly.

- **Deletion requires proof.** A file is only deleted when a manifest from the
  previous pass shows it existed then. A missing folder — an unmounted drive, a
  cloud client that has not started yet — is never read as "everything was
  deleted"; the link is skipped instead.
- **A mass delete aborts the whole pass.** If a pass proposes more deletions than
  the link's `MaxDelete` (default 50), nothing is applied at all. Not partially —
  nothing.
- **Deletes are recoverable.** Ordinary files go to the Recycle Bin. A
  dehydrated placeholder has no local content to put there, so deleting it
  propagates to the cloud service's own online recycle bin; set
  `HydrateBeforeDelete` on a link to pull content down first at the cost of a
  download per file. A network share or removable drive has no Recycle Bin, so
  there a deleted file is moved into a hidden `.driverelay-deleted\<timestamp>\`
  folder at that link root instead; empty it yourself when you no longer need it.
- **An incomplete listing never reads as deletions.** If any folder on either
  side cannot be listed, that link is skipped for the pass. Deletes are also
  re-checked just before they run.
- **Sync history is required once a link has run.** If a link's manifest is
  missing or unreadable, DriveRelay restores the previous copy (`.bak`) or stops
  the link, because without it deleted files would come back.
- **Junctions and symbolic links are not followed.** Whatever lies behind one is
  left untouched on both sides; `check` and `status` list them.
- **Conflicts keep both versions.** If both sides changed, the remote version is
  saved alongside the local one under a conflict name and nothing is discarded.
- **Deletions are not undone by possible edits.** When a previously synced file
  is deleted on one side and the other copy's metadata changed, DriveRelay leaves
  the deletion intact and preserves the surviving copy for review. The dashboard's
  **Review** button lists paths and resolution guidance.
- **Copies are atomic.** Content goes to a temp name and is moved into place, so
  a half-copied file is never visible as a complete one.
- **Recognized moves stay moves.** Moving or renaming an unchanged file within
  either linked folder moves its counterpart to the matching path. NTFS identity
  proves the match; DriveRelay never guesses from filename, size or time alone.
- **Files in use are left alone.** A file still being written, or held open by an
  application, is deferred to a later pass — it is never copied mid-write.
- **`check` writes nothing.** Run it before `sync`, and `sync -WhatIf` before
  anything you care about.
- **An unavailable folder is reported, never guessed at.** If a drive is not
  mounted, a folder has been deleted, or the cloud client is not running,
  DriveRelay says which of those it is and skips the link rather than treating
  an absent folder as "everything was deleted".

### When something is not available

These three look identical to the filesystem and mean very different things, so
they are reported separately:

| What you see | What it means | What to do |
| --- | --- | --- |
| **Drive X: is not available** | The volume is not mounted — an external disk unplugged, a share disconnected, a laptop undocked | Reconnect it; the next pass carries on where it left off |
| **Remote folder is missing** | The drive is there but the folder is not — deleted, renamed, or not yet recreated by the cloud client | Restore the folder, or `rm <id>` if the link is no longer wanted |
| **OneDrive is not running** | Both folders exist but the client is stopped | Start it. Local changes are still copied across and upload when it returns; cloud-only files are deferred rather than waited on |

The first two block the link and nothing is copied or deleted. The third does
not block: it degrades. Without the client running, a cloud-only file cannot be
fetched, so those are deferred immediately instead of burning a 30-minute
hydration timeout each.

The tray shows the specific cause in its tooltip and raises one balloon when the
state changes — not once per pass, so a disconnected drive does not nag you all
day. The dashboard colours the pair red when it cannot sync at all and amber when
it is merely degraded, with the full explanation in the tooltip.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows — nothing to install)
- No administrator rights. No services. Everything runs under your user account.

## Install

Download or clone the repository into a permanent local folder, then double-click
**`Setup.cmd`**. Keep the source folder in place: shortcuts launch the scripts
and generated launcher from that location. No administrator rights are needed.
For everyday usage, see the [operating guide](docs/04-operations.md).

Before updating the source folder, pause syncing, let the current pass finish,
and exit the tray and dashboard. Preserve `config/links.json`,
`config/settings.json`, `config/excludes.txt`, `state/` and operational logs.
Rerun `Setup.cmd` after updating. Setup does not guard against a running pass.

It creates a Start Menu entry, an optional Windows startup entry, and a hidden
launcher for the tray agent.

Setup builds `DriveRelay.exe` using the .NET Framework compiler included
with Windows. Startup apps in Task Manager identifies this launcher as
**DriveRelay**. Rerun Setup to update an older shortcut that displays `wscript`.

Options are passed straight through:

```
Setup.cmd -IntervalMinutes 5
Setup.cmd -NoAutoStart
```

To remove it again, double-click **`Uninstall.cmd`**. That takes away the
shortcuts and the tray agent and leaves your links, your sync history and every
file in every linked folder exactly as they are.

The Inno Setup installer was withdrawn on 2026-10-26. Its build tools and tests
are no longer part of the project. Historical packages and verification evidence
may remain locally under ignored `release/`; they are not the current install
method. An existing packaged installation retains its own Windows uninstall
entry; source setup does not migrate or uninstall it.

## Use

Three interfaces drive one engine — the command line, the tray agent and the
dashboard all call the same code, so nothing behaves differently unattended.

### Command line

```
.\DriveRelay.ps1 add    <local> <remote>   Register a new link pair
.\DriveRelay.ps1 list                      Show all registered links
.\DriveRelay.ps1 rm     <id>               Unregister a link (no files touched)
.\DriveRelay.ps1 pause  <id>               Disable a link
.\DriveRelay.ps1 resume <id>               Re-enable a paused link
.\DriveRelay.ps1 check  [<id>]             Report what a sync would do. Writes nothing
.\DriveRelay.ps1 sync   [<id>]             Apply it (runs even while syncing is paused)
.\DriveRelay.ps1 run                       Quiet pass for automation; honours the pause
.\DriveRelay.ps1 status [<id>]             Per-link state and outstanding work
.\DriveRelay.ps1 start                     Install scheduled background task
.\DriveRelay.ps1 stop                      Remove scheduled task
.\DriveRelay.ps1 config                    View or update global settings
```

A first run seeds: `-Seed Local` or `-Seed Remote` decides which side is
authoritative that one time. After seeding, the pair is two-way. Where a file
exists on both sides and differs, the seed side's version becomes current and
the other version is kept beside it as a conflict copy; nothing is overwritten
without a copy.

```powershell
.\DriveRelay.ps1 add "D:\Tally Prime" "D:\OneDrive\Tally Prime" -Seed Local
.\DriveRelay.ps1 check
.\DriveRelay.ps1 sync -WhatIf
.\DriveRelay.ps1 sync
```

### Tray agent and dashboard

`Setup.cmd` installs a tray agent that runs a pass on a timer and shows state by
the clock. Right-click it for sync-now, pause, settings and the log; double-click
for the dashboard, which shows each folder pair as a card with its status, paths
and last sync.

When conflict copies exist, a card's **Duplicates** section expands within the
dashboard to list them alongside their original filenames and paths. It checks
both folders when opened, even for paused pairs.
CLI `status` shows the same list. The tray continues to warn while conflict copies
remain, using the last pass's snapshot. These are the timestamped copies DriveRelay
creates to preserve both versions when a file changes in both places.

> Windows 11 hides new tray icons behind the chevron next to the clock. Drag it
> onto the taskbar to keep it visible.

## Configuration

`config/settings.json` and `config/links.json` are created on first run — they are
deliberately **not** in this repository, because they describe your actual
folders. See `config/settings.example.json` and `config/links.example.json` for
the shapes.

| Setting | Default | Meaning |
| --- | --- | --- |
| `IntervalMinutes` | 10 | Minutes between background passes |
| `SettleMinutes` | 3 | How long a file must be quiet before it is eligible |
| `MaxDelete` | 50 | Deletions in one pass above which the pass aborts entirely |
| `HydrateBeforeDelete` | true | Download placeholders before deleting, so the Recycle Bin holds real content |
| `StartWithWindows` | true | Start the tray agent at logon; the dashboard's setting creates or removes the Startup shortcut |
| `StartDelaySeconds` | 90 | Wait after logon before the first pass, so cloud clients can mount |
| `LogLevel` | INFO | `DEBUG`, `INFO`, `WARN` or `ERROR`; INFO records what changed |
| `LogMaxSizeMB` | 1 | Size at which `driverelay.log` rotates |
| `LogKeepFiles` | 3 | Rotated generations kept (`driverelay.1.log` ..) |
| `LogMaxAgeDays` | 60 | Rotated generations older than this are deleted; `0` turns the age limit off |
| `Paused` | false | Set by the tray's Pause; automatic passes skip while true, an explicit `sync` still runs |

Each value is checked on its own: an invalid one falls back to its default
without affecting the others. Change settings with `config`, the dashboard or
the tray rather than by hand while DriveRelay is running.

`config/excludes.txt` holds wildcard patterns matched against file names —
Office lock files, `*.tmp`, `Thumbs.db` and so on.

### Moving files and folders

Move files between subfolders or rename them on either side as usual. After a
successful sync has recorded their filesystem identities, DriveRelay recognizes
unchanged NTFS files at their new paths and moves the other copies without
recopying content. A populated folder move is applied file by file; folders left
empty by those moves are removed. Empty folders are still not tracked.

`check` and `status` show `MoveLocal` or `MoveRemote` with the old and new paths.
Proven moves do not count as deletions against `MaxDelete`. Files must be settled
and unlocked, and a destination collision or a change since planning defers the
move. Moves never overwrite a file or copy across volumes.

Existing links collect identities during their next successful ordinary pass.
Moves made before that baseline, files changed while moving, cross-volume moves,
hard links, and providers that do not expose usable NTFS identities use the
existing copy/delete/conflict rules. Cloud placeholders are queried through
metadata handles without reading their contents; provider-specific cloud upload
behavior remains the desktop client's responsibility.

## Project layout

```
DriveRelay.ps1        CLI and command router
DriveRelayTray.ps1    System tray agent
DriveRelayUI.ps1      Dashboard window
DriveRelay.exe        Generated silent launcher with DriveRelay branding
OneDriveGate.ps1      Optional: hold the OneDrive client off during work hours
Setup.cmd             Double-clickable installer
Uninstall.cmd         Double-clickable uninstaller
Install.ps1           The install itself (shortcuts, launcher, startup entry)
Uninstall.ps1         Reverses it
lib/                  Actions, Availability, Conflicts, DashboardScan,
                      FileIdentity, Hydration, Icons, Logging, LogViewer,
                      Manifest, Pass, Provider, Registry, Settings, Settle,
                      Startup
config/               settings, links, exclude patterns
docs/                 rationale, architecture, operations, runbook, audit
tests/                regression suite
tools/                icon/launcher sources, build scripts and output cleanup
release/              Historical packages and saved verification evidence
                      (local, ignored by Git)
LICENSE               MIT
```

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-DriveRelay.ps1
```

Assertions cover settings persistence, the link registry and icon
generation, the suite covers the parts that can lose data:

- the `Compare-LinkState` classification table,
  including the deleted-here-but-edited-there cases where guessing wrong either
  resurrects deleted files or destroys new ones
- the `MaxDelete` abort, including the exactly-at-the-limit boundary, asserting
  that an aborted pass leaves every file on disk
- conflict forking — that both versions survive and which one ends up where
- manifest round-tripping, including the empty-array and single-entry JSON
  shapes the code carries explicit workarounds for
- deletion conflicts, surviving-copy preservation, persistent review details,
  and destination deletions before and during a queued copy
- moves in both directions, populated folder renames, retained file identities,
  collisions, queued changes, locked and unsettled files, and legacy baselines

Tests log to `tests/test-run.log` and never to the production log. They do use
the real Recycle Bin, since that is the delete path under test.

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-BuildCleanup.ps1`
to verify output cleanup in a disposable fixture. Its junction-refusal checks
require permission to create a Windows directory junction. The cleanup helper
accepts only repository-root `build` and `dist`, validates all requested trees
before deletion, and leaves saved evidence under `release/` alone.

## Audit

A full audit is in [docs/06-audit.md](docs/06-audit.md): twelve findings, each
labelled with how it was established — reproduced against running code, or read
from source. All twelve are now fixed, and the ones that could be pinned to a
behaviour have regression tests.

The audit is kept in the repository rather than quietly folded into the history
because the reasoning is worth more than the diffs. It records what was wrong,
how it was proven wrong, and what the safety properties actually rest on.

No known outstanding defects. That is not the same as "no bugs" — see the
authorship note below for how much weight to put on it.

## Authorship

**Jayadheer Chitta — concept, direction, decisions, review.**
**Claude (Opus 5), Anthropic's model, in Claude Code — implementation.**

The idea is Jayadheer's, and so is everything that decided the shape of it. This tool
exists because the real cost was correctly identified as the cloud filter driver
rather than the network, and because the useful move was not to make a sync root
faster — you cannot — but to move the work outside it and let a background
process absorb the latency instead of a person. The consequential calls came
from the same place:

- that the slowness gets **delegated, not removed** — the framing the whole
  architecture follows
- that **rclone over the API was the wrong answer**, because it would mean
  retiring the desktop client and holding cloud credentials; this design holds
  none and makes no network calls
- that **live Tally company data sets the safety bar** — if a design can corrupt
  an open company file, it is not a design, and that constraint is why files in
  use are deferred rather than copied
- what "recoverable" has to mean before a delete is allowed to happen at all

Claude wrote the code that implements those decisions: the sync engine, the tray
agent, the dashboard, the installer, the test harness, this README and the audit
in `docs/06-audit.md`. Where the docs report a measurement — the placeholder
attribute transitions, the fact that `Get-FileHash` silently downloads a
placeholder — that was measured on the machine and then written up, not assumed.

The division is worth stating plainly because it changes how you should read
this repository. A human decided what it must never do. An AI wrote the code
that tries to honour that. The second half deserves more scrutiny than the
first: read the safety model above, run `check` and `sync -WhatIf` before
trusting this with anything you cannot replace, and read the audit for what is
known to be wrong.

Bugs found in AI review are listed in `docs/06-audit.md` with the method used to
confirm each one — reproduced against running code, or identified by reading it.
All twelve findings are resolved; the audit's Summary and Resolutions sections
record their disposition and the checks performed at that time.

## License

[MIT](LICENSE) © 2026 Jayadheer Chitta.

Use it, change it, ship it. The only condition is that the copyright notice
travels with it. Note the warranty disclaimer in particular: this is a tool that
deletes files, and it comes with no guarantee of any kind. That is not
boilerplate here — read the safety model, run `check` first, and keep backups
you did not make with this.
