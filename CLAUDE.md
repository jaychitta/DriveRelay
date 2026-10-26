# DriveRelay (formerly SyncOrchestrator)

DriveRelay relays files between a high-speed local NTFS working folder and a cloud drive folder (OneDrive, Google Drive, Dropbox, etc.) on Windows.

## Project Structure

- `DriveRelay.ps1`: Primary CLI and sync engine. Modern verb-based commands: `add`, `list`, `rm`, `pause`, `resume`, `check`, `sync`, `status`, `start`, `stop`.
- `DriveRelayTray.ps1`: System tray agent. Runs periodic background passes, handles tray icon state, right-click menu, and balloon notifications.
- `DriveRelayUI.ps1`: Modern dark-mode popup dashboard. Card-style folder link status, inline pause/resume toggles, folder adding dialog, and manual sync triggering.
- `DriveRelay.exe`: Generated branded windowless launcher for the tray agent; the Startup shortcut targets it so Task Manager identifies the app as DriveRelay.
- `tools/DriveRelayLauncher.cs` / `tools/New-Launcher.ps1`: Launcher source and build script, using the Windows .NET Framework compiler (no extra SDK).
- `DriveRelayTray.vbs`: Legacy silent launcher retained for compatibility with manual launches.
- `Setup.cmd`: Double-clickable installer. Wraps `Install.ps1` with a process-scoped execution policy, guards against a partial extraction, passes arguments through, and offers to start the tray agent.
- `Uninstall.cmd`: Double-clickable uninstaller wrapping `Uninstall.ps1`.
- `Install.ps1`: Creates Startup and Start Menu shortcuts and sets up the tray agent.
- `Uninstall.ps1`: Cleanly uninstalls shortcuts, launcher, and background processes.
- `README.md`: Public-facing overview, safety model, install/usage, known issues, authorship (concept and direction: Jayadheer Chitta; implementation: Claude).
- `LICENSE`: MIT, © 2026 Jayadheer Chitta.
- `.gitignore`: Keeps runtime state and personal data (`config/links.json`, `config/settings.json`, `state/`, `*.log`) out of version control.
- `OneDriveGate.ps1`: Process lifecycle controller for the OneDrive desktop client (Grace -> Blocked -> Resumed).
- `lib/`: Modular PowerShell helper scripts:
  - `DashboardScan.ps1`: Read-only availability and conflict inventories in a background PowerShell runspace. Dashboard rendering reads completed results, rejects inventories for changed registries, and never waits for folder scans.
  - `Conflicts.ps1`: Lists timestamped conflict copies and live deletion conflicts, with paths and review guidance. Used by CLI, dashboard Duplicates/Review controls and tray warnings. Live deletion classification depends on `Manifest.ps1` and `Availability.ps1`.
  - `Actions.ps1`: Sync action execution, guarded atomic copying, deletion with safety thresholds, and removal of folders a pass empties. Depends on `Availability.ps1`, `Manifest.ps1` and `Conflicts.ps1`. Deletion conflicts preserve the survivor without undoing the deletion and retain their old manifest entry.
  - `Availability.ps1`: Distinguishes an unmounted drive from a deleted folder from a stopped cloud client, and reports what to do about each. Must be dot-sourced before `Actions.ps1`.
  - `Hydration.ps1`: OneDrive file hydration and cloud dehydration handlers.
  - `Icons.ps1`: GDI+ programmatic icon drawing for tray and fallback icon generation.
  - `Logging.ps1`: Structured console and file logging. Severity threshold (`DEBUG`/`INFO`/
    `WARN`/`ERROR`, default `INFO`) plus generational rotation to `driverelay.<n>.log`, each
    generation also aged out past `LogMaxAgeDays` regardless of how many `LogKeepFiles` allows
    for. Dot-sourced into the entry scripts, so its state variables are deliberately named to
    avoid colliding with their parameters (`$script:LogThreshold`, not `$script:LogLevel`).
  - `LogViewer.ps1`: Read-only log viewer used by the tray and dashboard.
  - `Manifest.ps1`: Metadata-only snapshots and change tracking. Loads `FileIdentity.ps1`; records optional per-side NTFS IDs and pairs unchanged tracked moves into `MoveLocal`/`MoveRemote`. Produces `DeletionConflict` for a tracked deletion versus changed survivor, and records destination parents for queued-copy/move checks. Never hashes cloud content.
  - `FileIdentity.ps1`: Zero-access Windows metadata handles for NTFS file IDs (volume, file index, creation time), excluding hard links and unsupported filesystems. Native same-volume rename refuses overwrites and copying across volumes. Loaded by `Manifest.ps1` in every engine/inventory host.
  - `Pass.ps1`: Sync pass orchestration logic. Collapses runs of no-op passes into one
    hourly heartbeat line, tracking the streak in `state/lastpass.json`.
  - `Provider.ps1`: Cloud provider detection and label resolution.
  - `Registry.ps1`: Link registration and persistence.
  - `Settle.ps1`: Settle time detection for in-flight file writes.
  - `Settings.ps1`: Centralized configuration management (get/save/update settings).
- `config/`:
  - `settings.json`: Centralized application and timing configuration. Generated at runtime; gitignored.
  - `links.json`: Registered link pairings between local and cloud directories. Generated at runtime; gitignored (contains real user paths).
  - `settings.example.json` / `links.example.json`: Committed templates showing the shapes of the two generated files.
  - `excludes.txt`: Default ignore / exclusion patterns.
- `assets/`:
  - `DriveRelay.ico`: Multi-resolution Windows icon (16x16 through 256x256, 32-bit RGBA).
  - `DriveRelay.png`: High-resolution transparent PNG icon badge.
  - `DriveRelay_badge.png`: Full-bleed rounded badge master.
- `tests/`:
  - `Test-DriveRelay.ps1`: Automated regression test suite.
  - `Test-BuildCleanup.ps1`: Disposable-fixture checks for output removal, preservation, invalid requests and linked-path refusal. Real-junction checks need Windows junction creation permission.
- `build/` / `dist/`: temporary generated work. `tools/Clear-BuildOutput.ps1` accepts only these two repository-root directories, validates all targets before removal and refuses links. Clear stale output before builds and remove temporary output after its consumers finish.
- `release/`: ignored local historical packages, checksums, inventories and saved verification evidence. Preserve these records during housekeeping. Inno Setup support was withdrawn on 2026-10-26; its builder, template, configuration helper and installer test are removed. Source setup through `Setup.cmd` / `Install.ps1` remains supported.
- `DriveRelay.ico`: Root-level icon for direct shortcut association.
- `docs/`:
  - [01-why.md](docs/01-why.md): Original problem and design rationale.
  - [02-current-state.md](docs/02-current-state.md): Dated development-machine measurements, not a live inventory.
  - [03-architecture.md](docs/03-architecture.md): Engine, safety rules, modules and source installation.
  - [04-operations.md](docs/04-operations.md): Current commands, settings and installation guidance.
  - [05-runbook.md](docs/05-runbook.md): Migration, recovery and troubleshooting procedures.
  - [06-audit.md](docs/06-audit.md): Historical code audit, with all 12 findings resolved in its Summary and Resolutions sections.
  - [changelog.md](docs/changelog.md): Changes, verification limits and pending work; read the latest entries before resuming.

## What to read

Read README.md and the documentation map above before implementation work.
For engine changes, read architecture and the audit's resolutions; for UI or
operator behavior, read operations; for setup, also read the source
installation section of architecture. Use the runbook for migration/recovery.
Before reporting completion, update the changelog, run `git diff --check`, and
perform checks appropriate to the change. Engine changes use
`tests/Test-DriveRelay.ps1`; cleanup changes also use `tests/Test-BuildCleanup.ps1`
with Windows PowerShell 5.1. Record skipped checks and their limits. Do not run
live syncs or install the application merely to verify source changes.

## CLI Quick Reference

```
DriveRelay add    <local> <remote>    Register a new link pair
DriveRelay list                       Show all registered links
DriveRelay rm     <id>                Unregister a link
DriveRelay pause  <id>                Disable a link
DriveRelay resume <id>                Re-enable a paused link
DriveRelay check  [<id>]              Report what a sync would do
DriveRelay sync   [<id>]              Apply it
DriveRelay status [<id>]              Per-link state and outstanding work
DriveRelay start                      Install scheduled background task
DriveRelay stop                       Remove scheduled task
DriveRelay config                     View or update global settings
```

Global settings live in `config/settings.json`. Log verbosity and retention are
`LogLevel` (`DEBUG`/`INFO`/`WARN`/`ERROR`), `LogMaxSizeMB`, `LogKeepFiles` and `LogMaxAgeDays`;
at `INFO` the log records what changed, and `DriveRelay config -LogLevel DEBUG` restores the
per-file and per-pass detail for diagnosis. `LogMaxAgeDays` (default 60) deletes a rotated
generation once it is that old, regardless of `LogKeepFiles` — a size-only cap otherwise lets
a quiet link's history sit indefinitely.

Note that the entry scripts capture `$PSBoundParameters` once as `$script:Typed`. Command
functions must use that: inside a function `$PSBoundParameters` is the function's own and is
always empty, which silently discards every caller override.

## Workflow Rules

- Update `docs/changelog.md` on every task.
- Update `CLAUDE.md` whenever architecture, dependencies, or file structures change.
