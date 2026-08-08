# Changelog

All notable changes to DriveRelay (formerly SyncOrchestrator) will be documented in this file.

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
