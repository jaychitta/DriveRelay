# DriveRelay (formerly SyncOrchestrator)

DriveRelay relays files between a high-speed local NTFS working folder and a cloud drive folder (OneDrive, Google Drive, Dropbox, etc.) on Windows.

## Project Structure

- `DriveRelay.ps1`: Primary CLI and sync engine. Modern verb-based commands: `add`, `list`, `rm`, `pause`, `resume`, `check`, `sync`, `status`, `start`, `stop`.
- `DriveRelayTray.ps1`: System tray agent. Runs periodic background passes, handles tray icon state, right-click menu, and balloon notifications.
- `DriveRelayUI.ps1`: Modern dark-mode popup dashboard. Card-style folder link status, inline pause/resume toggles, folder adding dialog, and manual sync triggering.
- `DriveRelayTray.vbs`: Silent windowless launcher for the system tray agent.
- `Setup.cmd`: Double-clickable installer. Wraps `Install.ps1` with a process-scoped execution policy, guards against a partial extraction, passes arguments through, and offers to start the tray agent.
- `Uninstall.cmd`: Double-clickable uninstaller wrapping `Uninstall.ps1`.
- `Install.ps1`: Creates Startup and Start Menu shortcuts and sets up the tray agent.
- `Uninstall.ps1`: Cleanly uninstalls shortcuts, launcher, and background processes.
- `README.md`: Public-facing overview, safety model, install/usage, known issues, authorship (concept and direction: Jayadheer Chitta; implementation: Claude).
- `LICENSE`: MIT, © 2026 Jayadheer Chitta.
- `.gitignore`: Keeps runtime state and personal data (`config/links.json`, `config/settings.json`, `state/`, `*.log`) out of version control.
- `OneDriveGate.ps1`: Process lifecycle controller for the OneDrive desktop client (Grace -> Blocked -> Resumed).
- `lib/`: Modular PowerShell helper scripts:
  - `Actions.ps1`: Sync action execution, file copying, deletion with safety thresholds. Depends on `Availability.ps1`.
  - `Availability.ps1`: Distinguishes an unmounted drive from a deleted folder from a stopped cloud client, and reports what to do about each. Must be dot-sourced before `Actions.ps1`.
  - `Hydration.ps1`: OneDrive file hydration and cloud dehydration handlers.
  - `Icons.ps1`: GDI+ programmatic icon drawing for tray and fallback icon generation.
  - `Logging.ps1`: Structured console and file logging.
  - `Manifest.ps1`: State manifests, file checksums, and change tracking.
  - `Pass.ps1`: Sync pass orchestration logic.
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
- `DriveRelay.ico`: Root-level icon for direct shortcut association.
- `docs/`:
  - `changelog.md`: Record of project changes and updates.
  - `06-audit.md`: Full code audit — 12 findings, each labelled by how it was established (reproduced against running code, or read from source).

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

## Workflow Rules

- Update `docs/changelog.md` on every task.
- Update `CLAUDE.md` whenever architecture, dependencies, or file structures change.
