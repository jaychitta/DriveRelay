# DriveRelay code audit (second)

**Date:** 2026-11-05
**Scope:** every script in the repository at commit `2b42a7e` — 26 PowerShell files plus
`Setup.cmd`, `Uninstall.cmd`, the VBS and C# launchers, configuration templates, tests and
documentation; about 9,800 lines.
**Performed by:** Claude via Claude Code, commissioned by Jayadheer Chitta.
**Previous audit:** [06-audit.md](06-audit.md) (2026-08-08), all 12 findings resolved.

Locations are given by function, not line number: the fixes below move lines.

---

## Method

| Check | Result |
| --- | --- |
| Source review, engine (`Manifest`, `FileIdentity`, `Actions`, `Settle`, `Hydration`, `Availability`, `Pass`) | read in full |
| Source review, state and concurrency, UI/tray/CLI, setup/build and docs | three parallel reviewers; every finding acted on was re-read against the code |
| Parse check, regression suite, PSScriptAnalyzer | **not run** — the audit ran in a Linux sandbox with no PowerShell; installing it was not permitted |
| Runtime reproduction | none; findings are by reading, and "needs Windows" marks claims about Windows behaviour that should be confirmed there |
| Live links, installation | not touched |

Because nothing was executed, every fix below is unverified until `tests/Test-DriveRelay.ps1`
passes under Windows PowerShell 5.1.

---

## Prior resolutions re-checked

| # | Status |
| --- | --- |
| 1 DeleteRemote binding | holds (regression test present) |
| 2 cross-side overlap | holds (tests cover chains in both directions) |
| 3 double-click scope | holds; the same closure technique broke the log viewer (U2) |
| 4 settings overwrite overrides | holds; the same dialog dropped other settings (U1) |
| 5 links.json lock | holds for writes; lock falls back to unlocked if it cannot be created (R8) |
| 6 install interval message | holds; an invalid interval is still echoed as given (S6) |
| 7 tray pause persisted | holds; "Sync now" while paused misreports (U5) |
| 8 concurrent log writers | partly: the append retry exists, but rotation has no lock (R9) |
| 9 Get-LinkCount | holds |
| 10 engine test coverage | holds and grew; seeding, mid-pass edits and listing errors were untested (now added) |
| 11 OneDriveGate later days | holds; see R11 for new issues |
| 12 repository hygiene | holds |

---

## What the design gets right

Load-bearing, and worth not regressing:

- **Copies recheck their destination twice**, before copying and before replacing, so an edit
  or deletion during a long hydration defers rather than clobbers.
- **Moves are proven, not guessed.** Pairing needs a unique NTFS ID on both the history and the
  current side, both versions unchanged, and the native rename refuses overwrites and
  cross-volume fallbacks.
- **Deletion conflicts preserve the survivor without undoing the deletion.**
- **The delete cap cannot be disabled** by 0 or a negative value; it aborts instead.
- **The dashboard scan is isolated**: it works on a JSON copy of the registry, never touches
  controls, rejects results for a changed registry, and never overlaps.
- **Duplicates and Review are read-only.**
- **Build-output cleanup cannot leave `build/` or `dist/`**: allow-list first, links refused on
  ancestors and descendants, all targets validated before the first delete.

---

## Findings

Severity: **high** can lose or corrupt user data; **medium** is a broken feature or misleading
state; **low** is minor. Status: **fixed** in this change, or **open** pending a decision.

### Engine

**E1. A listing error made files look deleted — high — fixed.**
`Get-SideSnapshot` ran `Get-ChildItem -Recurse -ErrorAction SilentlyContinue`. Any folder that
could not be listed (access denied, a path over 260 characters, a cloud provider that cannot
enumerate while its client is stopped — a non-blocking state) silently dropped its files, and
every tracked one then classified as deleted on that side, deleting its counterpart up to the
`MaxDelete` cap. *Fix:* any enumeration error throws and the link is skipped; only the
post-pass manifest refresh accepts a partial listing.

**E2. Deletes were not re-checked before being applied — high — fixed.**
Actions run in name order, so every delete came after every copy and hydration (up to 30
minutes per file). A counterpart restored, or the target edited on another PC, in that window
was deleted anyway. *Fix:* `Test-DeleteStillValid` re-checks both halves of the proof.

**E3. Edits made during a pass were absorbed into the baseline — high — fixed.**
The manifest commit recorded whatever was on disk at the end of the pass for every succeeded
path, including `InSync` ones. A file saved mid-pass was recorded as already synced and never
relayed; a later edit on the other side would then overwrite it. *Fix:* `Get-CommittedEntry`
records the source as planned and the destination only if it still holds that version.

**E4. Seeding overwrote differing files with no copy kept — high — fixed.**
`Invoke-LinkSeed` copied the seed side over any differing file on the other side with
`Move-Item -Force`: not a conflict copy, not the Recycle Bin. `check` listed those files as
`Conflict` (keep both), the opposite of what the seed would do, and the CLI default is
`-Seed Local`. *Fix:* the replaced version is renamed to a conflict copy first (a same-volume
rename, so a placeholder is not downloaded); `check` describes the seed.

**E5. "Deletes are recoverable" was not true everywhere — high — fixed (needs Windows).**
The shell deletes permanently on volumes with no Recycle Bin — network shares and removable
media, both advertised remote types — while the log said "in the Recycle Bin". Separately,
`UIOption.OnlyErrorDialogs` still shows modal error dialogs, and a file held open produces one,
stalling an unattended pass. *Fix:* `Test-RecycleBinVolume` (fixed local volumes only); elsewhere
the file is renamed into `<side root>\.driverelay-deleted\<timestamp>\`, which snapshots skip,
or deferred if that fails; held-open files are deferred before the shell is called. *Residual:*
an error dialog for other failures (for example access denied) is still possible, and a file
too large for the Recycle Bin is still deleted permanently by Windows.

**E6. Junctions and symbolic links were followed — medium — fixed (needs Windows).**
Windows PowerShell 5.1 recursion follows junctions, so a junction inside a link root synced —
and could delete through — a folder outside it. *Fix:* snapshots walk folder by folder and skip
junctions, mount points and directory symbolic links (cloud placeholder folders are reparse
points but not links); every path under a skipped link, on either side, gets no action and
keeps its manifest entry, so stopping following one cannot read as deletions. `check` and
`status` list them. *Needs Windows:* confirm `LinkType` reads `$null` on OneDrive placeholder
folders, and measure the per-folder walk on a large tree.

**E7. A missing or empty manifest erased history — medium — fixed.**
`Read-Manifest` treated a missing or empty file as "no history", so a crash between
`Move-Item -Force`'s delete and rename, or an unflushed write before a power cut, would undo
deletions and turn differences into conflicts. *Fix:* writes are flushed and swapped with
`File.Replace`, keeping `.bak`; `Repair-LinkManifest` restores a seeded link from `.tmp` then
`.bak`, or stops it with recovery guidance. Re-registration also sets the `.bak`/`.tmp` aside.

**E8. Stale manifest set aside outside the registry lock — medium — open.**
`add` and the dashboard register the link, then move the old manifest. A failed move, or a pass
starting in between, seeds against a previous registration's history. Fix: set aside inside
the `Add-Link` transaction, or give links a GUID-named state folder.

### State and concurrency

**R1. Provider auto-detection listed the whole tree — low — fixed.** A `foreach` over a
parenthesised `Get-ChildItem` collects everything before the 200-item `break`.

**R2. `settings.json` has no lock and resets on one bad value — medium — open.** A
non-numeric value passes the `-gt 0` check as a string, the cast throws, and the whole file
reads as defaults (including `Paused = false`), which the next tray toggle saves. The read
function also writes defaults when the file is missing, through a shared temp name. Fix:
per-field `TryParse`, a settings mutex, no writes from the reader.

**R3. Manifest write collides with the dashboard's reads — medium — partly fixed.** The
replace now retries; a reader could still hold the file through all retries.

**R4. A deferred-forever file is invisible at INFO — low — open.** A future last-write time
never settles, and deferrals do not break the idle streak. Per-link `SettleMinutes` and
`MaxDelete` are stored without range checks in `Add-Link`.

**R5. A single-link `sync <id>` overwrites the tray's whole-pass summary — low — open.**

**R8. Registry lock falls back to unlocked — low — open.** If the mutex cannot be created
(for example across elevation levels) writes proceed unlocked; the pass lock fails closed.

**R9. Log rotation races; orphaned generations — low — open.** Two writers rotating at once
can lose a generation; lowering `LogKeepFiles` leaves higher-numbered files forever.

**R11. OneDriveGate — low — open.** In the resumed phase a quit OneDrive is relaunched every
30 seconds; `-ResumeTime 17` parses as 17 days and never resumes; the process check matches
other users' sessions.

### UI, tray and CLI

**U1. Settings dialog reset other settings — medium — fixed.** It saved a hand-built object,
dropping log level and retention and reverting a pause made from the tray meanwhile.

**U2. Log viewer could not resolve its path — medium — fixed (needs Windows).** A
`GetNewClosure()` handler cannot call the script-scope `Get-DriveRelayLogPath`.

**U3. Spurious Review button before the first scan — low — fixed.** `@($null).Count` is 1.

**U4. Dashboard scan failed for every link without `excludes.txt` — low — fixed.**

**U5. Tray status misreports — medium — open.** "Sync now" and "Sync all now" run the silent
`run` verb, which does nothing while paused, yet the tray then shows "up to date"; a failed
pass (non-zero exit, no new summary) also shows as up to date.

**U6. Tray menu scans folders on the UI thread — medium — open.** Opening the menu runs a
recursive conflict-copy scan of every link.

**U7. Unhandled errors in some dashboard handlers — low — open.** Edit, pause, remove and
start-CLI handlers lack `try/catch`; a failure can leave buttons disabled.

**U8. `StartWithWindows` has no effect — medium — open.** Only the installer creates or
removes the Startup shortcut; the setting is stored and displayed only.

### Setup and uninstall

**S1. `&` in the install folder ran a command — low — fixed.** `Setup.cmd` echoed `%~dp0`
unquoted.

**S2. Uninstall deleted a tracked file and left the dashboard running — medium — fixed.** It
removed `DriveRelayTray.vbs` and stopped only the tray. (Waiting for an in-flight pass before
`-AlsoRemoveSettings` deletes `state\` remains open.)

**S3. Partial-extraction guard checks two files — low — open.**

**S6. Install echoes an invalid interval — low — open.** `-IntervalMinutes 0` is saved and
reported, but reads back as 10.

**S7. Install saves settings before steps that can fail — low — open.**

**S9. `start` re-creates the scheduled task alongside the tray — low — open.** Safe because of
the mutex, but redundant.

### Documentation

**D1. Drift — low — partly fixed.** Updated for this change: README safety model and seeding,
architecture safety rules, runbook recovery, `CLAUDE.md` module notes. Still stale: the README
settings table (log settings, `Paused`), the CLI quick reference's bare `DriveRelay` form and
missing `run`, `config` usage in operations, the manager-window status table, the Files table,
`links.example.json`'s `HydrateBeforeDelete`, and the `CLAUDE.md` file list (`tools/New-Icons.ps1`,
two tracked `.ico` files).

---

## Summary

| Severity | Found | Fixed here | Partly fixed | Open |
| --- | --- | --- | --- | --- |
| High | 5 | 5 (E1–E5) | 0 | 0 |
| Medium | 11 | 5 (E6, E7, U1, U2, S2) | 1 (R3) | 5 (E8, R2, U5, U6, U8) |
| Low | 15 | 4 (R1, U3, U4, S1) | 1 (D1) | 10 |

The five high findings share one theme: each was a way for the engine to act on a picture of
the folders that was incomplete (E1), stale (E2, E3), or overstated in what it promised (E4,
E5). The fixes hold the engine to its own rule — act only on proof, and keep a copy of
anything it replaces or removes.

## Verification still owed

1. Run `tests/Test-DriveRelay.ps1` under Windows PowerShell 5.1. Section 9c covers E1–E7;
   its junction checks need junction creation permission and report `[SKIP]` without it.
2. Confirm on a OneDrive folder that placeholder folders are walked (E6) and that a pass over a
   large tree is not materially slower.
3. Confirm `Test-RecycleBinVolume` on a mapped network drive, a UNC remote and a USB stick (E5).
4. Open the log viewer from the tray and dashboard (U2).
