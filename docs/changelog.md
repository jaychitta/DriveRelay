# Changelog

All notable changes to DriveRelay (formerly SyncOrchestrator) will be documented in this file.

## [Maintenance] - 2026-10-18 — prepare current source for GitHub backup

- Included the pending installer, move detection, deletion review and dashboard
  work in the source backup. Removed client-identifying document names from
  operational notes before publication. Private links, settings, history, logs,
  generated executables and build output remain excluded from Git.
- Verification: 234 core checks and 53 isolated installer checks passed. Live
  linked folders and the running installation were not changed.

## [Unreleased] - 2026-10-15 — distributable Windows installer

### Added
- `tools/New-Installer.ps1` and an Inno Setup 6 template produce
  `dist/DriveRelay-Setup-1.0.0.exe`, a SHA-256 sidecar and a payload inventory.
  Each build compiles a fresh branded launcher into unique staging, using an
  explicit 29-file allowlist with runtime modules, icons, examples and public
  usage/audit documentation. Private configuration, links, manifests, logs,
  tests and repository metadata are excluded.
- Per-user setup wizard with a configurable install folder (LocalAppData
  Programs by default), Start Menu entries, optional Windows startup/desktop
  shortcuts, launch-on-finish and a Windows Installed Apps uninstall entry.
- Upgrades and removal check the global tray/pass mutexes before proceeding.
  The installer owns its shortcuts and removal inventory; generated settings,
  links, state and logs survive. Customized exclusions are neither overwritten
  nor removed. A small settings helper persists the startup choice without
  changing other supported preferences. Source-folder Setup.cmd remains usable.
- Rebuild and end-user instructions in README/operations; generated build and
  release directories are gitignored. Output is unsigned.

### Verified
- Windows PowerShell 5.1 installer verification: 53 passed. Compiled the release
  and exercised the same template with isolated integration paths and no Windows
  uninstall registry registration: active-app blocking, new install into a path
  with spaces/ampersand, shortcut targets/options, packaged CLI loading, upgrade,
  and removal. Link/history/log/exclusion sentinels survived upgrade and removal;
  pause and sync preferences survived startup-option changes.
- Core regression suite: 232 passed, 0 failed (hard-link scenario skipped where
  creation is denied). Parser checks across 27 PowerShell scripts and
  `git diff --check` passed. No live installation or linked folders were changed.

## [Unreleased] - 2026-10-15 — relay moves and renames

### Added
- Unchanged tracked files moved or renamed within either linked folder now
  produce `MoveLocal` / `MoveRemote` and move the counterpart without recopying
  content. Populated folder moves are handled file by file and emptied old
  counterpart directories are pruned. CLI check/status show old and new paths;
  link results and pass summaries retain the moved count.
- Metadata snapshots and manifests retain optional per-side NTFS identities
  (volume serial, file index and creation time). Windows metadata handles request
  zero content access and open reparse points without reading placeholder data.
  Old manifests remain compatible and collect identities on successful passes.

### Safety
- A move requires unique identity evidence, unchanged metadata on both sides,
  and the counterpart's original identity. Size/time matches alone never infer
  a move. Missing identities, hard links, moved-and-edited files and legacy
  baselines retain ordinary copy/delete/conflict handling.
- Both files must settle and be unlocked. Execution rechecks identities,
  metadata, old-path absence and the vacant destination/parent. Native renames
  refuse overwrites and cross-volume copying; failed/deferred moves retain the
  old baseline. Proven moves are removed from deletion-cap accounting.
- Empty folders and case-only renames remain outside the file-based model.

### Verified
- Windows PowerShell 5.1 regression suite: 232 passed, 0 failed. Covers moves
  both ways, folder renames with equal-size/time files, identity preservation,
  WhatIf, MaxDelete zero, baseline migration/retention, locks and settling,
  queued edits/replacements/deletions/collisions, ambiguous history and native
  overwrite refusal. The hard-link creation scenario was skipped because the
  execution environment denies creation; the test runs where permitted.
- Parser checks across 24 PowerShell scripts and `git diff --check` passed.
- Verification used isolated NTFS scratch folders; live cloud-placeholder
  move/hydration behavior and provider upload effects were not exercised.

## [Operations] - 2026-10-13 — review deletion and duplicate logs

- Reviewed active and retained logs, the October 7 duplicate report, and current
  metadata at the reported paths without running a sync or changing linked files.
- The October 7 report recorded nine Office conflict copies absent locally but
  present remotely. Retained logs contain failed remote deletion attempts for
  several of them at 19:26, with DeleteFile reporting file-not-found; the logs
  alone do not establish why those paths disappeared during that pass.
- All nine old Office duplicate paths are now absent on both sides. The latest
  pass summary still lists the a client guide conflict created October
  8 at 10:16, but its recorded paths are also now absent on both sides, so that
  summary is stale. Its creation was logged as a two-version conflict.
- Recent logs confirm local deletions are reaching the OneDrive folder, including
  Tally's TUPDATE.TSF on October 13 at 12:34. This verifies filesystem propagation,
  not the online OneDrive account's state.

## [Operations] - 2026-10-13 — start tray agent

- Launched `DriveRelay.exe` on request; launcher exited successfully and the
  held `Global\DriveRelayTray` mutex confirmed the tray agent was running.

## [Unreleased] - 2026-10-13 — name the startup app DriveRelay

### Fixed
- Startup and Start Menu tray shortcuts now target a branded `DriveRelay.exe`
  instead of `wscript.exe`, so Windows can identify the startup app as DriveRelay.
- Reinstalling with `-NoAutoStart` removes an existing DriveRelay Startup shortcut.

### Added
- Windowless launcher source and build script using Windows' .NET Framework
  compiler, with DriveRelay description, product name and embedded icon. The
  launcher resolves the tray script beside itself and starts PowerShell without
  a console window. Setup builds it; uninstall removes it and the legacy VBS.

### Verified
- Launcher compiled under Windows PowerShell 5.1; executable description and
  product name both read DriveRelay, with the Windows GUI subsystem.
- Isolated smoke launch from a path containing spaces and `&` executed the
  sibling tray stub, set its working directory and created no console window.
- Installed Startup and Start Menu tray shortcuts updated and read back to
  confirm they target `D:\DriveRelay\DriveRelay.exe` with no arguments.
- Windows PowerShell 5.1 parser checks and `git diff --check`: clean. Task Manager's
  displayed label still needs a visual check after reopening it.


## [Unreleased] - 2026-10-13 — responsive dashboard loading

### Fixed
- Opening and refreshing the dashboard no longer recursively scans every linked
  folder and compares manifests on the Windows Forms thread. A read-only
  background runspace collects availability, duplicates and deletion conflicts.
- Cards show Checking folders until results arrive, report scan failures, and
  discard results when link settings change. Scans never overlap and closing
  the dashboard requests cancellation without waiting for folder enumeration.

### Updated
- Live inventory refresh starts five seconds after the previous scan completes.
  Card expansion and other UI actions reuse the completed inventory.

### Verified
- Windows PowerShell 5.1 regression suite: 163 passed, 0 failed, including
  asynchronous inventory, single-duplicate array shape, deletion conflicts,
  read-only behavior, initial checking status and scan failure reporting.
- With the three configured links, initial card rendering measured 115 ms;
  live background inventory completed in about 19 seconds without scan errors.
  Closing during an active scan returned in 92 ms in a Windows Forms smoke test.
- PowerShell parser checks and `git diff --check` passed.

## [Unreleased] - 2026-10-08 — preserve deletions when the survivor appears changed

### Fixed
- A tracked deletion versus changed survivor metadata now produces
  `DeletionConflict` on either side. The deleted path stays absent, the survivor
  is preserved, and the old baseline remains until the user resolves it.
- Planned copies check destination metadata and the closest existing parent
  before copying and before replacing the destination. A deletion during a long
  pass defers the copy instead of recreating the file or folder. Conflict forks
  also guard their destinations.
- A single duplicate now retains its array shape when a dashboard card is built.
  PowerShell 5.1 previously unwrapped it, hiding the Duplicates button despite
  the badge correctly reporting one duplicate. A real-card construction test
  reproduced this and verifies both Duplicates and Review appear without overlap.

### Added
- Live dashboard **Review** lists deletion conflicts and paths, with instructions
  to delete the survivor or deliberately restore it. CLI check/status/sync and
  tray warnings report these separately from conflict copies. Pass summaries
  preserve their details, and unchanged deletion conflicts do not repeat balloons.
- Copy/delete decision reasons are logged at INFO; deletion conflicts and
  copies deferred because a destination changed are logged at WARN.
- Regression coverage for timestamp-only conflicts, both deletion directions,
  baseline retention, explicit resolution, WhatIf, summary serialization, queued
  and in-progress copy deletions, and actual dashboard control construction.

### Verified
- Windows PowerShell 5.1 regression suite: 154 passed, 0 failed.
- Parser checks across 20 project scripts and `git diff --check`: clean.

## [Unreleased] - 2026-10-08 — investigate restored Office subfolder

### Verified
- The owner clarified that DriveRelay restored the deleted subfolder locally.
  Logs confirm a copy to local of its workbook at 16:24:42 on October 8,
  with an earlier copy to local at 19:47:32 on October 7. INFO logging does
  not record the classification reason or the baseline used, so the cause
  of choosing a copy instead of deletion remains unverified.
- Checked for historical Office manifests: only the current manifest remains,
  so the pre-restoration baseline cannot be reconstructed from retained state.
- Traced and exercised the deletion branches using Windows PowerShell 5.1 in
  isolated scratch folders. With a baseline and unchanged remote metadata,
  local absence produces DeleteRemote. Changing only the remote timestamp by
  three seconds produces CopyToLocal despite identical content, and executing
  that copy recreates the deleted local subfolder. A missing baseline also
  produces CopyToLocal. The historical incident's exact branch remains unknown;
  these are verified code paths, not evidence of a historical timestamp change.
- At inspection the subfolder was absent on both sides and the read-only
  Office check proposed no file deletions. OneDrive was stopped and was
  started in the background; this does not explain the earlier restoration.
- No sync-engine changes or manual deletions were made.
- Investigated the Office duplicate count: a live metadata scan confirms one
  conflict copy of a client guide, present on both
  sides. Its creation is logged at 10:16:39 on October 8. The current dashboard
  creates the Duplicates control from the same live inventory as its badge;
  no dashboard process was running during inspection, so the reported missing
  control could not be verified visually.

## [Unreleased] - 2026-10-07 — identify DriveRelay conflict duplicates

### Updated
- Dashboard conflict duplicates now expand within their folder-pair card instead of opening
  a separate window. The **Duplicates** control is shown only when a live scan finds copies.
  The dashboard refreshes that inventory while open, so resolving a copy removes it promptly.
- Duplicates now displays original and duplicate filenames directly in a table,
  with per-copy **Open folder** buttons that select the duplicate in Explorer.
  Missing local/remote copies are labelled **Not present**.
- An aborted link's dashboard card now shows its saved abort reason (such as a
  delete limit being exceeded), rather than the generic **Needs attention**.
  Delete-limit warnings use concise, grammatical wording. Once a higher limit
  is saved, the stale warning becomes a neutral **Ready to sync** state.
- **Sync all now** waits for an in-progress pass before retrying, so a manual
  retry uses recently saved link settings instead of silently skipping.

### Fixed
- Manifest timestamps read from Windows PowerShell JSON retain their UTC instant
  instead of being shifted by the local timezone.

### Added
- Dashboard **Duplicates** and CLI `status` list existing conflict copies with
  original filenames and paths. Metadata-only scans cover both linked folders and
  group a copy present on both sides into one entry.
- Background passes retain `ConflictCopies` in `lastpass.json`; the dashboard and
  tray warn while copies remain, rather than only when a pass creates them.
- Regression coverage for naming, original/copy pairing, remote-only copies,
  grouping, removal and summary serialization.

### Limitations
- Recognizes DriveRelay's timestamped conflict naming format. Renamed files no
  longer match. The list checks live when opened; tray counts use the latest pass.

## [Unreleased] - 2026-09-08 — cap how long a rotated log is kept, by age not just size

Requested by Jayadheer Chitta: size-based rotation (added 2026-08-12) bounds the log by MB,
not by time — a quiet link could leave a generation sitting for a year without ever hitting
the 1 MB cap. Asked for an explicit time limit on top of that: 60 days, deleting whatever is
older regardless of size.

### Added
- **`LogMaxAgeDays` setting**, default 60. `Invoke-LogAgePurge` in `lib/Logging.ps1` deletes a
  rotated generation (`driverelay.1.log` ..) once its last write is older than this, on every
  call to `Invoke-LogRotation` — not only when a size rotation just fired, since a quiet link
  may never trigger one. Only rotated generations are ever removed this way; the active
  `driverelay.log` is not a candidate no matter its age. `0` disables the age cap and leaves
  `LogKeepFiles` as the only limit, matching the behaviour before this existed.
- Settable with `DriveRelay config -LogMaxAgeDays 60`, applied by all three entry points
  through the existing `Initialize-LoggingFromSettings` -> `Set-LogRotation` path.
- 5 assertions covering an aged-out generation being purged, a recent one surviving, the
  active log being left alone regardless of age, and `MaxAgeDays 0` disabling the cap; plus a
  `config -LogMaxAgeDays` round-trip through the real CLI alongside the existing
  `-SettleMinutes`/`-LogLevel` regression test. Suite is now 104 assertions, up from 97.

### Fixed
- **`config -LogMaxAgeDays` silently had no effect** — caught by the new CLI round-trip
  assertion before this shipped, not in the field. Same defect as the `LogLevel` /
  `LogThreshold` split recorded on 2026-08-12: `Logging.ps1` is dot-sourced into
  `DriveRelay.ps1`, so a `$script:LogMaxAgeDays` state variable there shares scope with the
  CLI's `-LogMaxAgeDays` parameter, and `Initialize-LoggingFromSettings` overwrote the value
  the caller typed before the command function ever read it. Renamed the internal variable to
  `$script:LogAgeCapDays`. Any new logging setting added here needs a name that does not match
  its CLI parameter, for the same reason.

## [Unreleased] - 2026-08-12 — correct the command reference in `docs/04-operations.md`

### Fixed
- **Four commands the CLI never accepted** — the reference block listed `DriveRelay.ps1 ui`,
  `log`, `install` and `uninstall`. None is in the `$Command` `ValidateSet` at
  `DriveRelay.ps1:35`, so each one failed parameter validation before doing anything. The
  functionality exists, just not there: the dashboard is `DriveRelayUI.ps1` (or the tray's
  **Open Dashboard...**), the log is opened by the tray's **View Log** item, and install /
  uninstall are `Install.ps1` / `Uninstall.ps1`, already documented lower in the same file.
  The doc now points at each of those instead of inventing a command; nothing was added to
  the CLI.
- **`start` / `stop` described as tray controls** — the doc said they launched and stopped the
  tray agent. `Invoke-StartCommand` (`DriveRelay.ps1:386`) registers a scheduled task named
  `DriveRelay` running `DriveRelay.ps1 run` every `IntervalMinutes`, and
  `Invoke-StopCommand` (`DriveRelay.ps1:415`) unregisters it (and the legacy
  `SyncOrchestrator` task). Neither touches the tray process. The doc was the wrong source;
  `CLAUDE.md` and the script's own header were already correct. `start`'s
  `-IntervalMinutes` is now shown, since it takes one.
- **Stale `compare` alias** — the same file claimed "`check` (or `compare`)". `compare` was
  the pre-rename name of the command and is not in the `ValidateSet` either; the rename is
  recorded further down this changelog. Dropped the parenthetical, and retitled the
  *Reading a compare report* section to *Reading a check report* so the old name does not
  survive as an implied command. `Compare-LinkState`, the internal classification function,
  is unrelated and unchanged.

## [Unreleased] - 2026-08-12 — cut the log down to what changed

Reported by Jayadheer Chitta: "log is becoming too long to handle."

Measured against the live log before the change: 2,820 lines, of which **1,856 (66%) were
idle bookkeeping** — `pass starting`, three all-zero per-link summaries, and
`pass finished: applied 0, conflicts 0, deleted 0`, written every ten minutes whether or not
anything moved. A further ~230 lines named the same handful of files as `deferred` over and
over, because a workbook held open by Excel or Tally is deferred again on every pass for as
long as it stays open. Actual copies, deletes and errors were a minority of the file.

### Added
- **Severity threshold in `lib/Logging.ps1`** — `DEBUG`, `INFO`, `WARN`, `ERROR`, with
  `Set-LogLevel` / `Get-LogLevel`. Anything below the active threshold is dropped before it
  reaches the file. `-Verbose` still shows every level: somebody watching a run by hand
  asked for the detail.
- **Generational rotation** — `Set-LogRotation` and `Invoke-LogRotation`. At the size cap the
  active log is renamed to `driverelay.1.log`, older generations shift down, and the oldest
  beyond `LogKeepFiles` is dropped.
- **Idle-pass heartbeat in `lib/Pass.ps1`** — consecutive passes that change nothing are
  collapsed into one line an hour: `idle: N pass(es) since <time>, nothing to relay`. The
  streak count and start are carried in `state/lastpass.json`, so they survive the separate
  processes a pass can run in. The next pass that does something reports the quiet stretch it
  followed: `pass finished: applied 3, ... (after 41 idle pass(es) since ...)`.
- **`LogLevel`, `LogMaxSizeMB`, `LogKeepFiles` settings**, defaulting to `INFO` / 1 MB / 3,
  settable with `DriveRelay config -LogLevel DEBUG` and applied by all three entry points
  through `Initialize-LoggingFromSettings`.
- 24 assertions covering the threshold, the rejected-typo case, rotation ordering and
  generation count, and idle-streak round-tripping. Suite is now 97 assertions, up from 74.

### Changed
- `pass starting`, the all-zero per-link summary, and the idle `pass finished` are now
  **DEBUG**. A link that moved something, aborted, or came back unavailable is still INFO.
- Per-file `deferred (...)` lines are now **DEBUG**. The deferred count still appears on the
  link summary and in `DriveRelay status`, so the backlog is not hidden — only the
  once-per-pass roll call of the same open files is.
- Rotation no longer truncates. The old behaviour re-read the file at 1 MB and rewrote the
  last 2,000 lines, discarding everything older and paying a full-file rewrite on every write
  above the threshold; rotation is now a rename.

### Fixed
- **`config -SettleMinutes`, `-MaxDelete`, `-IntervalMinutes` and `add -SettleMinutes` were
  silently ignored.** The command functions tested `$PSBoundParameters`, which inside a
  function is that function's own — and these take no parameters, so it was always empty.
  Every override read as "not supplied": the command printed the unchanged settings and
  reported nothing wrong. Now captured once at script scope as `$script:Typed`.
- **`Logging.ps1` shadowed the CLI's `-LogLevel`.** The file is dot-sourced into
  `DriveRelay.ps1`, so its `$script:LogLevel` was that script's scope — the same variable as
  the parameter — and `Initialize-LoggingFromSettings` overwrote the value the caller typed.
  Renamed to `$script:LogThreshold`, with the reason recorded at the declaration.

### Notes on scope
- Deferrals deliberately do **not** make a pass count as non-idle. A file held open all day
  would otherwise defeat the whole heartbeat.
- Nothing is dropped outright. `DriveRelay config -LogLevel DEBUG` restores the previous
  detail in full, and the fixed CLI now makes that flag work.
- Existing `state/lastpass.json` files predate the idle fields; they read as a fresh streak
  rather than failing, and there is a test for that.

## [Unreleased] - 2026-08-11 — remove folders a pass empties

Reported by Jayadheer Chitta while working through a `MaxDelete` abort on the `Tally-Prime`
link: "drive relay is leaving behind empty folders."

Structural, not a glitch. The snapshot in `lib/Manifest.ps1` is `-File` only and nothing in
the manifest describes a directory, so deleting a folder's files removed the files and left
the folder standing on the other side. Nothing in the engine would ever have cleaned it up.

### Added
- **`Remove-EmptiedDirectory`** in `lib/Actions.ps1` — removes folders left empty by a pass,
  walking upward toward the link root and stopping at the first folder that still holds
  something. Runs after the action loop, once per side.
- Seven assertions in `tests/Test-DriveRelay.ps1` section 8b covering the emptied folder, the
  nested parent, the folder with a survivor, and the hand-made empty folder. Suite is now
  74 assertions, up from 67.

### Notes on scope
- Only folders **this pass emptied** are considered — collected from the parents of files
  actually deleted. An empty folder the user created by hand is invisible to the sync model
  and is left alone; pruning it would be a change nobody asked for.
- The link root is never removed, even when it ends up empty.
- Deepest-first ordering, so a parent whose last remaining child is a folder emptied by the
  same pass is also removed on that run rather than surviving until the next one.
- A folder still holding deferred files stays: the prune runs after the deletes, so a folder
  that has not finished emptying is simply revisited on a later pass.
- Honours `-WhatIf` like every other writing step, so `check` still reports without touching
  anything.

## [Unreleased] - 2026-08-08 (c) — report unavailable drives and stopped cloud clients

Requested by Jayadheer Chitta: "if OneDrive or that particular drive is not turned on we
have to inform the same."

### Added
- **`lib/Availability.ps1`** — distinguishes three conditions that are identical to
  `Test-Path` but need different responses:
  - `DriveOffline` — the volume is not mounted (external disk unplugged, share
    disconnected, laptop undocked). Blocking. Names the drive letter.
  - `FolderMissing` — the drive is mounted but the folder is gone. Blocking.
  - `ClientNotRunning` — both folders exist but the cloud client is stopped. **Not**
    blocking: local changes still copy across and upload when it returns.
  - `NoRemote` — the link has no remote path configured.
  Detects OneDrive, Google Drive, Dropbox, Box, iCloud and Nextcloud by process name.
  Returns `$null` rather than `$false` for providers it cannot check, because "I cannot
  tell" and "it is not running" are different answers.
- Availability reported in `check`, `status`, `sync`, the tray tooltip and balloon, and
  the dashboard card badges.

### Changed
- **Hydration fails fast when the cloud client is not running.** `Wait-Hydrated` used to
  spend its full timeout — up to 30 minutes per file — waiting for a client that was not
  there. It now checks first and defers immediately.
- **Tray balloons fire on state change, not per pass.** A disconnected drive raised a
  warning every ten minutes all day; it now notifies once when the state changes.
- **Dashboard cards distinguish blocked from degraded** — red for "cannot sync at all",
  amber for "running but degraded", with the full explanation and remedy in a tooltip.
  The status line is re-evaluated live when the window opens and when the tray menu opens,
  rather than reflecting the last pass.
- Availability is reported separately from failure in the pass summary. A drive that is
  not plugged in is not a sync error, and calling it one trains people to ignore the
  warning that matters.
- `Invoke-LinkSync` results carry `State` and `Detail` alongside `Message`.

### Verified
- 67 assertions passed, 0 failed (was 51). New coverage: `DriveOffline` vs `FolderMissing`
  on a real unmounted drive letter, `NoRemote`, that an unavailable link aborts without
  touching either side, and that an unknown provider reports `$null` rather than "stopped".
- Parse check across all 19 `.ps1` files: clean.
- End-to-end `status` output confirmed against a three-link scenario in an isolated copy
  (healthy / unmounted drive / deleted folder), so no live link was involved.
- The new dependency (`Actions.ps1` → `Availability.ps1`) was caught by the test suite
  before it could reach a caller.

## [Unreleased] - 2026-08-08 (b) — audit findings fixed

All twelve audit findings resolved. Detail and reproduction steps in `docs/06-audit.md`.

### Fixed
- **Cross-side link overlap (finding 2).** `Add-Link` now checks both sides of the new link
  against both sides of every existing link — all four combinations — instead of only
  local-vs-local and remote-vs-remote. Registering `A ↔ B` and then `B ↔ C` was accepted,
  leaving two links driving folder `B` from two separate manifests. The error now names
  which side collided with which.
- **Registry write races (finding 5).** New `Invoke-RegistryTransaction` holds a named mutex
  (`Global\DriveRelayRegistry`) around every read-modify-write of `links.json`. A dashboard
  Pause landing between a pass's read and its write is no longer lost.
- **Dashboard double-click (finding 3).** The card double-click handlers captured `$Link`
  from a scope that no longer existed when the handler ran. Now snapshotted with
  `.GetNewClosure()`, and the folder is checked before Explorer is launched.
- **Global settings wiping per-link overrides (finding 4).** Propagating settle time and
  max-delete to existing links is now opt-in behind an unticked checkbox, rather than
  silently overwriting exactly the links that had been customised.
- **Persisted pause (finding 7).** `Paused` is now a setting. The tray restores it at
  startup, the dashboard shows it in the status bar, `DriveRelay config` reports it, and
  unattended `run` passes honour it — while an explicit `sync` still works, because pausing
  means "stop doing this on your own", not "refuse when I ask".
- **Dropped log lines (finding 8).** `Write-Log` retries up to four times with a short
  backoff instead of silently swallowing the first write collision. Rotation is separately
  guarded. It still never throws.
- **Installer interval message (finding 6).** Reports the interval and start delay actually
  in effect rather than the parameter defaults, and warns when syncing is paused.
- **`Get-LinkCount` (finding 9).** Empty, null and malformed registries report 0, not 1.
- **`OneDriveGate` daily rollover (finding 11).** The gate re-arms at midnight; each day
  gets its own blocked phase. Previously `$resumed` latched true permanently, so a machine
  left running resumed once and never blocked again — silently.

### Added
- **Engine test coverage (finding 10)** — the suite goes from 17 assertions to 51, covering
  the full `Compare-LinkState` classification table (all eight outcomes), the `MaxDelete`
  abort including the exactly-at-the-limit boundary, conflict forking, manifest
  round-tripping and exclude handling. Finding 1 now has a direct regression test.
- Tests redirect logging to `tests/test-run.log`. They had been writing scratch link ids
  into the production `driverelay.log` — a defect introduced and fixed within this change,
  verified by asserting the production log's byte size is unchanged across a full run.

### Verified
- 51 passed, 0 failed.
- Parse check across all 18 `.ps1` files: clean.
- Pause guard exercised in an isolated copy with an empty registry, so no live link was
  reachable: `run` skips when paused and proceeds when not.

## [Unreleased] - 2026-08-08

Audit, installer and first publication to git.

Direction, decisions and review: Jayadheer Chitta. Implementation: Claude (Opus 5) via Claude
Code. Findings in this entry are reported for triage — the medium-severity ones were
deliberately left unfixed, since what changes in the engine is the owner's call.

### Added
- **`Setup.cmd`** — double-clickable installer. A `.ps1` cannot be double-clicked (Windows
  opens it in Notepad, and the default execution policy blocks it), so this wrapper starts
  PowerShell with the policy scoped to the one process, changing nothing about the machine.
  It verifies `powershell.exe` is on the PATH, refuses to run if `Install.ps1` or
  `DriveRelayTray.ps1` are missing from the folder, passes any arguments straight through
  to `Install.ps1` (`Setup.cmd -IntervalMinutes 5`, `Setup.cmd -NoAutoStart`), propagates
  the installer's exit code, and offers to start the tray agent when it finishes.
- **`Uninstall.cmd`** — the double-clickable counterpart, wrapping `Uninstall.ps1`.
- **`docs/06-audit.md`** — full code audit of all 18 PowerShell files (3,679 lines).
  Twelve findings, each labelled with how it was established: reproduced against running
  code, or identified by reading it.
- **`README.md`** — project overview, safety model, install and usage, known issues, and an
  explicit statement that the project was written by AI.
- **`.gitignore`** — excludes `config/links.json`, `config/settings.json`, `state/` and
  `*.log` from version control. These describe the owner's actual folders and record real
  client filenames; publishing them would have leaked personal data. All are recreated
  automatically on first run.
- **`config/links.example.json`** and **`config/settings.example.json`** — the shapes of the
  two ignored config files, so a fresh clone has something to read.
- **`LICENSE`** — MIT, © 2026 Jayadheer Chitta. Chosen for a tool people should be free to
  adapt to their own cloud client and folder layout; the warranty disclaimer matters more
  than usual for software that deletes files.

### Audit findings (reported, not changed)
Full detail and reproduction steps in `docs/06-audit.md`.
- The 24 `DeleteRemote` failures in `driverelay.log` (2026-08-07 17:36) were the
  `OneDrive`→`Remote` property rename reaching a call site that still read the old name.
  Already fixed in source at 17:50; confirmed gone by reproduction. Those 24 deletions
  remain outstanding and will apply on the next pass over the `Office` link.
- `Add-Link` does not reject cross-side overlap: registering `A ↔ B` then `B ↔ C` is
  accepted, leaving two links driving folder `B`. Confirmed by reproduction.
- The dashboard's card double-click handlers read `$Link` from a scope that is gone by the
  time the handler runs; the Edit and Pause buttons in the same function already work
  around this via `$this.Tag`.
- Saving global Settings force-writes `SettleMinutes` and `MaxDelete` onto every link,
  discarding the per-link overrides the Edit dialog exists to set.
- `links.json` is read-modify-written without a lock, so a UI edit during a pass can be lost.
- Lower-severity: installer misreports the configured interval; tray pause is not persisted;
  log lines are dropped under write contention; `Get-LinkCount` returns 1 for a malformed
  registry; `OneDriveGate` cannot resume on any day but the one it started.
- The test suite (17 assertions, all passing) covers settings, registry and icons, but not
  `Compare-LinkState`, the `MaxDelete` abort, conflict forking or manifest round-tripping —
  the code that can lose data.

### Verified
- Parse check across all 18 `.ps1` files: clean.
- `tests/Test-DriveRelay.ps1`: 17 passed, 0 failed.
- `Setup.cmd` exercised in a sandbox against a stub payload — argument passthrough, exit-code
  propagation, missing-payload guard, and both branches of the start prompt.
- No sync pass was run against the live links during the audit.

## [Unreleased] - 2026-08-07

### Changed
- **Renamed project from SyncOrchestrator to DriveRelay.**
- **Completely redesigned CLI** from two-level `link add/list/remove/enable` and `schedule install/remove` commands to simple, flat, modern verbs:
  - `link add -Local <path> -Remote <path>` → `add <local> <remote>` (positional arguments)
  - `link list` → `list`
  - `link remove -Id <id>` → `rm <id>` (positional)
  - `link enable -Id <id> [-Off]` → `pause <id>` / `resume <id>` (separate clear commands)
  - `compare [-Id <id>]` → `check [<id>]` (positional)
  - `sync [-Id <id>]` → `sync [<id>]` (positional)
  - `status [-Id <id>]` → `status [<id>]` (positional)
  - `schedule install` → `start`
  - `schedule remove` → `stop`
- Named `-Id`, `-Local`, `-Remote` flags are still accepted for backward compatibility.
- Internal pass mutex renamed from `Global\SyncOrchestratorPass` to `Global\DriveRelayPass`.
- Scheduled task name changed from `SyncOrchestrator` to `DriveRelay` (the `stop` command cleans up both old and new task names).
- Atomic copy temp suffix changed from `.syncorch.tmp` to `.driverelay.tmp`.
- Log file name changed from `syncorch.log` to `driverelay.log`.
- Status display now shows `[paused]` instead of `[disabled]` for clarity.
- Renamed asset files to `DriveRelay.ico`, `DriveRelay.png`, and `DriveRelay_badge.png`.
- **Dynamic Path Portability**: Eliminated hardcoded `D:\SyncOrchestrator` fallbacks across `lib/Logging.ps1`, `lib/Registry.ps1`, `lib/Pass.ps1`, `lib/Manifest.ps1`, `lib/Actions.ps1`, and `OneDriveGate.ps1`, enabling the project folder to be renamed or moved anywhere (e.g. `D:\DriveRelay`) seamlessly.
- **Dynamic VBS Launcher**: Updated `DriveRelayTray.vbs` and `Install.ps1` to dynamically resolve the script directory using `Scripting.FileSystemObject`.
- **Legacy Cleanup**: Removed obsolete `SyncOrch.ps1`, `SyncOrchTray.ps1`, `SyncOrchUI.ps1`, `SyncOrch.ico`, and `assets/syncorch*` files.
- **Documentation Updates**: Updated `docs/03-architecture.md`, `docs/04-operations.md`, and `docs/05-runbook.md` with new `DriveRelay` commands and references.
- Updated `CLAUDE.md` with new project structure and CLI quick reference.
- Updated `Install.ps1` and `Uninstall.ps1` to configure shortcuts, tray agent, and cleanup for DriveRelay.

### Added
- **Modern System Tray Agent (`DriveRelayTray.ps1`)**:
  - Direct integration with high-resolution `DriveRelay.ico` application icon.
  - Redesigned context menu with bold DriveRelay header, sync status with timestamp, manual sync trigger, pause/resume, and dashboard launcher.
  - Balloon notifications for conflict warnings.
- **Modern Dark-Themed Popup Dashboard (`DriveRelayUI.ps1`)**:
  - Dark title bar using Windows DWM immersive attribute (`DwmSetWindowAttribute`).
  - Card-based folder link rows showing link ID, provider badge, local-to-remote paths, and last sync timestamp.
  - Per-link color-coded status badges (Up to date [Green], Paused [Gray], Needs attention [Amber]).
  - Inline Pause/Resume toggle button for each folder link.
  - Action bar with `+ Add folder`, `Sync all`, `View log`, and `Close` buttons.
  - Add folder dialog with cloud provider detection, direction selector, and safe delete toggle.
- Multi-resolution Windows `.ico` application icon (16x16 to 256x256 32-bit RGBA).
- Created `assets/DriveRelay.png` and `assets/DriveRelay_badge.png` high-resolution transparent master icon images.
- Added `CLAUDE.md` documenting project structure, CLI reference, and documentation workflows.
- **Centralized Settings Architecture (`lib/Settings.ps1` & `config/settings.json`)**:
  - Global configurable parameters for sync interval (`IntervalMinutes`, default 10m), settle time (`SettleMinutes`, default 3m), mass-deletion threshold (`MaxDelete`, default 50), cloud dehydration safety (`HydrateBeforeDelete`), and Windows startup options (`StartWithWindows`, `StartDelaySeconds`).
  - Automatic fallback and self-healing serialization.
- **Settings UI & Link Customization (`DriveRelayUI.ps1`)**:
  - Global `Settings` button and modal dialog (`Show-SettingsDialog`) with numeric up/downs, checkboxes, and immediate persistence.
  - Per-link `Edit` button and dialog (`Show-LinkEditDialog`) to override settle time, max delete thresholds, and cloud hydration behavior on an individual folder pair basis.
  - Dynamic `Set-LinkSettings` API in `lib/Registry.ps1`.
- **System Tray Agent Settings Integration (`DriveRelayTray.ps1`)**:
  - Direct `Settings...` option in tray context menu.
  - Dynamic polling of interval settings on timer ticks so interval modifications apply immediately without requiring tray process restart.
- **CLI Configuration Command (`DriveRelay.ps1`)**:
  - Added `DriveRelay config` and `DriveRelay settings` commands to inspect and modify settings via CLI flags.
  - Integrated settings defaults into `add` and `start` CLI commands.
- **Automated Test Suite (`tests/Test-DriveRelay.ps1`)**:
  - Added 17 automated tests covering settings management, persistence, link registry modification, icon rendering, and CLI configuration.
- **Complete Visual Icon Integration**:
  - Generated crisp multi-resolution icon binaries (`DriveRelay.ico`, `driverelay-sync.ico`, `driverelay-warn.ico`) across standard Windows frame sizes.
  - Added branded visual logo & banner to `DriveRelayUI.ps1` dashboard header.
  - Propagated `DriveRelay.ico` window icons across all dialogs (Main Dashboard, Add Folder, Settings, Edit Link).
  - Updated all Start Menu and Startup shortcuts to use the new `DriveRelay.ico` branding.
