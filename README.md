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
  download per file.
- **Conflicts keep both versions.** If both sides changed, the remote version is
  saved alongside the local one under a conflict name and nothing is discarded.
- **Copies are atomic.** Content goes to a temp name and is moved into place, so
  a half-copied file is never visible as a complete one.
- **Files in use are left alone.** A file still being written, or held open by an
  application, is deferred to a later pass — it is never copied mid-write.
- **`check` writes nothing.** Run it before `sync`, and `sync -WhatIf` before
  anything you care about.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows — nothing to install)
- No administrator rights. No services. Everything runs under your user account.

## Install

Download or clone the repository, then double-click **`Setup.cmd`**.

It creates a Start Menu entry, an optional Windows startup entry, and a hidden
launcher for the tray agent. Options are passed straight through:

```
Setup.cmd -IntervalMinutes 5
Setup.cmd -NoAutoStart
```

To remove it again, double-click **`Uninstall.cmd`**. That takes away the
shortcuts and the tray agent and leaves your links, your sync history and every
file in every linked folder exactly as they are.

## Use

Three interfaces drive one engine — the command line, the tray agent and the
dashboard all call the same code, so nothing behaves differently unattended.

### Command line

```
DriveRelay add    <local> <remote>    Register a new link pair
DriveRelay list                       Show all registered links
DriveRelay rm     <id>                Unregister a link (no files touched)
DriveRelay pause  <id>                Disable a link
DriveRelay resume <id>                Re-enable a paused link
DriveRelay check  [<id>]              Report what a sync would do. Writes nothing
DriveRelay sync   [<id>]              Apply it
DriveRelay status [<id>]              Per-link state and outstanding work
DriveRelay start                      Install scheduled background task
DriveRelay stop                       Remove scheduled task
DriveRelay config                     View or update global settings
```

A first run seeds: `-Seed Local` or `-Seed Remote` decides which side is
authoritative that one time. After seeding, the pair is two-way.

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
| `StartWithWindows` | true | Start the tray agent at logon |
| `StartDelaySeconds` | 90 | Wait after logon before the first pass, so cloud clients can mount |

`config/excludes.txt` holds wildcard patterns matched against file names —
Office lock files, `*.tmp`, `Thumbs.db` and so on.

## Project layout

```
DriveRelay.ps1        CLI and command router
DriveRelayTray.ps1    System tray agent
DriveRelayUI.ps1      Dashboard window
OneDriveGate.ps1      Optional: hold the OneDrive client off during work hours
Setup.cmd             Double-clickable installer
Uninstall.cmd         Double-clickable uninstaller
Install.ps1           The install itself (shortcuts, launcher, startup entry)
Uninstall.ps1         Reverses it
lib/                  Actions, Hydration, Icons, Logging, Manifest, Pass,
                      Provider, Registry, Settings, Settle
config/               settings, links, exclude patterns
docs/                 rationale, architecture, operations, runbook, audit
tests/                regression suite
LICENSE               MIT
```

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-DriveRelay.ps1
```

51 assertions. Alongside settings persistence, the link registry and icon
generation, the suite covers the parts that can lose data:

- the full `Compare-LinkState` classification table — all eight outcomes,
  including the deleted-here-but-edited-there cases where guessing wrong either
  resurrects deleted files or destroys new ones
- the `MaxDelete` abort, including the exactly-at-the-limit boundary, asserting
  that an aborted pass leaves every file on disk
- conflict forking — that both versions survive and which one ends up where
- manifest round-tripping, including the empty-array and single-entry JSON
  shapes the code carries explicit workarounds for

Tests log to `tests/test-run.log` and never to the production log. They do use
the real Recycle Bin, since that is the delete path under test.

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
Twelve findings, two of them reproduced. None of the medium findings have been
fixed yet; they are reported for triage, not quietly patched.

## License

[MIT](LICENSE) © 2026 Jayadheer Chitta.

Use it, change it, ship it. The only condition is that the copyright notice
travels with it. Note the warranty disclaimer in particular: this is a tool that
deletes files, and it comes with no guarantee of any kind. That is not
boilerplate here — read the safety model, run `check` first, and keep backups
you did not make with this.
