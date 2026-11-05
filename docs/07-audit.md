# DriveRelay code audit (second)

**Date:** 2026-11-05
**Scope:** every script in the repository at commit `2b42a7e` (that version no longer exists:
the git history was replaced by a single version on 2026-11-05) — 26 PowerShell files plus
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
| Parse check, regression suite, PSScriptAnalyzer | **not run** during the audit — it ran in a Linux sandbox with no PowerShell. Run afterwards on Windows (see Verification still owed, item 1); PSScriptAnalyzer dropped by Jay on 2026-11-05 |
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
keeps its manifest entry, so stopping following one cannot read as deletions. Seeding applies
the same rule (a gap found in the pull request review: a destination-side junction hid its files
from the seed's snapshot but not from its writes). `check` and `status` list them. *Needs Windows:* confirm `LinkType` reads `$null` on OneDrive placeholder
folders, and measure the per-folder walk on a large tree.

**E7. A missing or empty manifest erased history — medium — fixed.**
`Read-Manifest` treated a missing or empty file as "no history", so a crash between
`Move-Item -Force`'s delete and rename, or an unflushed write before a power cut, would undo
deletions and turn differences into conflicts. *Fix:* writes are flushed and swapped with
`File.Replace`, keeping `.bak`; `Repair-LinkManifest` restores a seeded link from `.tmp` then
`.bak`, or stops it with recovery guidance. Re-registration also sets the `.bak`/`.tmp` aside.

**E8. Stale manifest set aside outside the registry lock — medium — fixed.**
`add` and the dashboard registered the link, then moved the old manifest. A failed move, or a
pass starting in between, seeded against a previous registration's history, which can propose
deletes. *Fix:* `Add-Link -StateRoot` renames the whole `state\<id>\` folder aside inside the
registry transaction and before the save, so a failure registers nothing. When there is history
to move it first holds the pass lock, so a pass of the removed link that is still finishing
cannot write the old manifest back; an add during a running pass is refused with a retry
message. Lock order (pass, then registry) matches the pass, so they cannot deadlock.

### State and concurrency

**R1. Provider auto-detection listed the whole tree — low — fixed.** A `foreach` over a
parenthesised `Get-ChildItem` collects everything before the 200-item `break`.

**R2. `settings.json` has no lock and resets on one bad value — medium — fixed.** A
non-numeric value passed the `-gt 0` check as a string, the cast threw, and the whole file
read as defaults (including `Paused = false`), which the next tray toggle saved; `[bool]"false"`
read as true; the reader wrote defaults when the file was missing, through a shared temp name.
*Fix:* each field is validated on its own (`TryParse`, explicit `true`/`false`); the reader never
writes and retries a briefly locked file instead of reading "not paused"; changes go through
`Update-AppSettings` under a `Global\DriveRelaySettings` mutex; writes use a per-writer temp
file and an atomic `File.Replace`; an unparseable file is copied aside before being replaced.

**R3. Manifest write collides with the dashboard's reads — medium — fixed.** The dashboard
reads every manifest every few seconds, and `Get-Content` opens without delete sharing, which
makes the pass's replace fail after its files were already copied — the next pass then sees
false conflicts. *Fix:* every reader of a replaced state file (manifests, `settings.json`,
`lastpass.json`, in the engine, tray and dashboard) uses `Read-SharedTextFile`, which opens
with read/write/delete sharing, so the atomic replace proceeds while a read is in flight; the
replace still retries briefly. `lastpass.json` is now written with an atomic replace too
instead of `Move-Item -Force`, which deleted it before renaming.

**R4. A deferred-forever file is invisible at INFO — low — fixed.** A future last-write time
never settled, deferrals did not break the idle streak, and per-link `SettleMinutes` and
`MaxDelete` were stored without range checks. *Fix:* a last-write time more than a minute in
the future counts as settled (the held-open check still applies); the hourly idle heartbeat
names how many files are waiting; `Add-Link` rejects negative values.

**R5. A single-link `sync <id>` overwrites the tray's whole-pass summary — low — fixed.**
`lastpass.json` now keeps per-link results; a single-link sync replaces only its own entry,
keeps the other enabled links', and leaves the idle streak alone. `sync <id>` on a paused link
now says it is paused rather than "no enabled links".

**R8. Registry lock falls back to unlocked — low — fixed.** If the mutex could not be created
(for example across elevation levels) writes proceeded unlocked. It now fails closed, like the
pass lock, with a message about the elevated window.

**R9. Log rotation races; orphaned generations — low — fixed.** Two writers rotating at once
could lose a generation; lowering `LogKeepFiles` left higher-numbered files forever. *Fix:*
rotation runs under a `Global\DriveRelayLogRotation` lock and re-checks the size once held; the
purge removes any generation numbered above `LogKeepFiles` as well as those past
`LogMaxAgeDays`, across every generation on disk, at most hourly per process and after each
rotation.

**R11. OneDriveGate — low — fixed.** In the resumed phase a quit OneDrive was relaunched every
30 seconds; `-ResumeTime 17` parsed as 17 days and never resumed; the process check matched
other users' sessions. *Fix:* OneDrive is started once on entering the resumed phase;
`ResumeTime` must be `HH:mm` under 24 hours; only the current session's processes count.

### UI, tray and CLI

**U1. Settings dialog reset other settings — medium — fixed.** It saved a hand-built object,
dropping log level and retention and reverting a pause made from the tray meanwhile.

**U2. Log viewer could not resolve its path — medium — fixed (needs Windows).** A
`GetNewClosure()` handler cannot call the script-scope `Get-DriveRelayLogPath`.

**U3. Spurious Review button before the first scan — low — fixed.** `@($null).Count` is 1.

**U4. Dashboard scan failed for every link without `excludes.txt` — low — fixed.**

**U5. Tray status misreports — medium — fixed.** "Sync now" and "Sync all now" ran the silent
`run` verb, which does nothing while paused, yet the tray then showed "up to date"; a failed
pass (non-zero exit, no new summary) also showed as up to date. *Fix:* both buttons run
`sync -WaitForPass` (an explicit sync, which works while paused); the tray and dashboard check
the child's exit code and show "last sync failed" with a once-per-state balloon; the CLI logs
any unhandled error before exiting non-zero; the tray re-reads the pause from settings after
each pass and keeps the paused icon and status.

**U6. Tray menu scans folders on the UI thread — medium — fixed.** Opening the menu ran a
recursive conflict-copy scan of every link and live availability checks. *Fix:* a background
runspace probe (availability and duplicate count) runs at start, every minute, after each pass
and on menu open; the menu shows the latest completed result and never waits for it.

**U7. Unhandled errors in some dashboard handlers — low — fixed.** "Sync all now" re-enables
its buttons if the sync cannot start; Edit/Save, Pause/Resume and Remove show a message when
the registry change fails (for example a lock timeout). The Add dialog's Recycle Bin option now
starts from the global default, as the CLI does.

**U8. `StartWithWindows` has no effect — medium — fixed.** Only the installer created or
removed the Startup shortcut. *Fix:* `lib/Startup.ps1` holds the shortcut logic for both the
installer and the dashboard; the dashboard's checkbox shows whether the shortcut exists, applies
the change, and saves the setting only after the shortcut matches it.

### Setup and uninstall

**S1. `&` in the install folder ran a command — low — fixed.** `Setup.cmd` echoed `%~dp0`
unquoted.

**S2. Uninstall deleted a tracked file and left the dashboard running — medium — fixed.** It
removed `DriveRelayTray.vbs` and stopped only the tray. `-AlsoRemoveSettings` now waits up to
two minutes for the pass lock and holds it while removing `state\`, or keeps everything and
says to retry.

**S3. Partial-extraction guard checks two files — low — fixed.** `Install.ps1` now checks
every file it needs (entry scripts, all `lib` modules, launcher sources, `excludes.txt`) before
changing anything and names what is missing; `Setup.cmd` keeps its two quick checks.

**S6. Install echoes an invalid interval — low — fixed.** `-IntervalMinutes 0` was saved and
reported, but read back as 10. Install now refuses an interval below 1.

**S7. Install saves settings before steps that can fail — low — fixed.** Settings are now
saved after the launcher and shortcuts exist, through `Update-AppSettings`.

**S9. `start` re-creates the scheduled task alongside the tray — low — fixed.** Still safe
because of the pass lock; `start` now says so when the tray's Startup shortcut exists and how
to keep only one, and the operations doc says the task is for machines without the tray.

### Documentation

**D1. Drift — low — fixed.** Brought in line with the code: README safety model, seeding,
settings table (log settings, `Paused`, per-field validation) and CLI reference (`.\DriveRelay.ps1`
form, `run`); architecture safety rules and component list (`Invoke-LinkSync`, `OneDriveGate`,
`Setup.cmd`/`Uninstall.cmd`, `Clear-BuildOutput`); operations tray menu, manager-window statuses
and buttons, full `config` usage including `-HydrateBeforeDelete:$false`, Files table
(`settings.json`, `onedrivegate.log`, `.driverelay-deleted`); runbook recovery; the CLI's own
usage header; Uninstall's header; `settings.example.json` (`Paused`); `links.example.json`
(`HydrateBeforeDelete` true, as CLI-added links inherit); `CLAUDE.md` file list and module notes.

---

## Summary

| Severity | Found | Fixed here | Partly fixed | Open |
| --- | --- | --- | --- | --- |
| High | 5 | 5 | 0 | 0 |
| Medium | 11 | 11 | 0 | 0 |
| Low | 15 | 15 | 0 | 0 |

The five high findings share one theme: each was a way for the engine to act on a picture of
the folders that was incomplete (E1), stale (E2, E3), or overstated in what it promised (E4,
E5). The fixes hold the engine to its own rule — act only on proof, and keep a copy of
anything it replaces or removes.

## Verification still owed

1. **Done 2026-11-05.** 27 PowerShell files parse. The first run of
   `tests/Test-DriveRelay.ps1` under Windows PowerShell 5.1 stopped at the second settings
   save: `File.Replace` was given `$null`, which PowerShell passes as an empty string, so
   every replace of `settings.json` and `state/lastpass.json` failed. Fixed with
   `[NullString]::Value`; the suite then passed 283, failed 0, skipped 0 (junction checks
   included). See the changelog entry of the same date.
2. **Done 2026-11-05 (read-only).** On `D:\OneDrive\Personal` and `D:\OneDrive\Office` every
   folder is a placeholder reparse point, none reads as a link, none was skipped, and the
   folder-by-folder walk found the same files as a recursive listing (2,975 and 12,762). Time:
   0.8 s against 0.1 s (Personal) and 3.0 s against 0.4 s (Office) for the bare listing; the
   walk also reads each file's NTFS identity. Explained to Jay as the cost of the E6 safety
   fix; Jay **accepted** it on 2026-11-05.
3. **Partly done 2026-11-05.** `Test-RecycleBinVolume` returns true for C: and D: (fixed) and
   false for UNC paths and the CD drive. No mapped network drive or USB stick is attached;
   Jay does not use DriveRelay with USB media, so the USB case is **not applicable**. The
   mapped-drive case rests on the `DriveType` check and was not run; Jay marked it **not
   applicable** on 2026-11-05 (all links are on D:).
4. **Done 2026-11-05 by Jay.** Log viewer opens from both the tray and the dashboard (U2).
5. **Open.** Tray "Sync now" while paused, and the menu with an unreachable remote (U5, U6).
   On 2026-11-05 Jay found paused could not be told from "needs attention": both used the
   amber warning icon. Paused now has its own grey icon; steps 2-4 to be rerun with it. The "last sync failed" case is to be skipped: it needs the live
   `config\links.json` made unreadable.
6. **Done 2026-11-05 by Jay.** Dashboard "Start with Windows" removes and restores the
   Startup shortcut and the box shows the saved state (U8).
7. **Done 2026-11-05.** Two processes writing 600 lines each past a 20 KB cap left
   generations 1 and 2 in order, with no torn lines (R9). But about two in three lines were
   lost: each writer's `Add-Content` collided and gave up after its retries. **Fixed
   2026-11-05:** writers now take turns through a named lock per log file
   (`Global\DriveRelayLogWrite-<hash>`, two-second wait, retries kept as a fallback). Two
   processes writing 300 lines each kept 68 of 600 with the old code and 600 of 600 with the
   new; the regression suite now includes this check. `OneDriveGate.ps1` refuses `-ResumeTime 17`
   and `25:00` and accepts `17:45`. With OneDrive closed and the resume time passed, it started
   OneDrive once and logged no further start over nine polls (R11). A second `/shutdown` sent
   seconds after start was ignored by OneDrive, so "stays quit" rests on the gate's log.
8. **Done 2026-11-05.** `Install.ps1` from a copy without `lib\Settle.ps1` refused, named the
   file, and created no shortcut or settings file (S3).
