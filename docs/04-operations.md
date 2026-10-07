# Operations

## Everyday use

The tray icon by the clock is the normal interface.

| Menu item | What it does |
|---|---|
| *(top line)* | Current state — up to date, syncing, or needs attention |
| Sync now | Runs a pass immediately |
| Pause syncing | Stops automatic passes until resumed |
| Open Dashboard... | Opens the manager window |
| View Log | Opens `driverelay.log` |
| Exit | Stops the agent until next logon |

A balloon appears only when something needs a person — a conflict, a failure, or an aborted
pass. Routine syncs are silent.

**Windows 11 hides new tray icons.** If it is not by the clock, click the chevron. Drag it onto
the taskbar to keep it there, or turn it on under
Settings > Personalization > Taskbar > Other system tray icons.

## The manager window

Lists every linked pair with the drive it detected and a status:

| Status | Meaning |
|---|---|
| Ready | Linked and seeded |
| Not copied yet | Registered, first sync not run |
| Needs attention | Last pass aborted — usually the delete cap |
| Paused | Link disabled |

Double-click a row to open that folder. **Add Folder...** takes two folders and a direction.
**Remove** unregisters a link; both folders keep all their files.

## Command line

```
DriveRelay.ps1 add     -Local <path> -Remote <path> [-Seed Local|Remote]
                       [-Provider Auto|CloudFiles|Plain] [-SettleMinutes 3]
                       [-MaxDelete 50] [-HydrateBeforeDelete] [-NoDehydrate]
DriveRelay.ps1 list
DriveRelay.ps1 rm      -Id <id>
DriveRelay.ps1 pause   -Id <id>
DriveRelay.ps1 resume  -Id <id>

DriveRelay.ps1 check   [-Id <id>] [-Detailed]     reports; writes nothing
DriveRelay.ps1 sync    [-Id <id>] [-WhatIf]       applies
DriveRelay.ps1 run                                quiet pass, for automation
DriveRelay.ps1 status  [-Id <id>]

DriveRelay.ps1 start   [-IntervalMinutes 10]      installs the scheduled background task
DriveRelay.ps1 stop                               removes the scheduled background task

DriveRelay.ps1 config  [-LogLevel DEBUG]
                       [-LogMaxSizeMB 1] [-LogKeepFiles 3] [-LogMaxAgeDays 60]
                                                   shows or changes global settings
```

`start` and `stop` register and unregister a Windows scheduled task named `DriveRelay`, which
runs `DriveRelay.ps1 run` every `IntervalMinutes` while you are logged in. Neither one starts
or stops the tray agent — that is the tray's own **Exit** menu item and the Startup shortcut
`Install.ps1` creates.

Three things are not CLI commands, and are reached elsewhere:

| Want | Where it is |
|---|---|
| The dashboard | `DriveRelayUI.ps1`, or **Open Dashboard...** on the tray menu |
| The log | Open `driverelay.log`, or **View Log** on the tray menu |
| Install / uninstall | `Install.ps1` and `Uninstall.ps1` — see below |

`-Remote` is any folder — OneDrive, Google Drive, Dropbox, a network share, another disk.
`-OneDrive` still works as an alias.

### Adding a folder safely

```powershell
.\DriveRelay.ps1 add -Local "D:\Work\Foo" -Remote "D:\OneDrive\Foo" -Seed Remote -HydrateBeforeDelete
.\DriveRelay.ps1 check -Id Foo -Detailed
.\DriveRelay.ps1 sync  -Id Foo -WhatIf
.\DriveRelay.ps1 sync  -Id Foo
```

`check` and `-WhatIf` both write nothing. Use them on anything you care about.

## Reading a check report

```
    ~ CopyToRemote     sub\fresh.txt
        new locally | not yet: still settling
```

`~` marks a file a real pass would defer. The reason is always one of:

| Reason | Meaning |
|---|---|
| still settling | Changed too recently; the settle window has not elapsed |
| held open | An application has the file locked |
| excluded | Matches a pattern in `config\excludes.txt` |

## Options per link

| Option | Default | Meaning |
|---|---|---|
| `SettleMinutes` | 3 | How long a file must be quiet before it is eligible |
| `MaxDelete` | 50 | A pass proposing more deletions aborts without applying anything |
| `HydrateBeforeDelete` | off | Download cloud-only files before deleting so the Recycle Bin keeps a copy |
| `Dehydrate` | on | Free space on the remote side after syncing |
| `Provider` | Auto | Force `CloudFiles` or `Plain` if detection is wrong |
| `Enabled` | on | Disable to pause one link |

## Unsticking things

**A link says "Needs attention".** The last pass aborted, almost always the delete cap. Run
`status -Id <id>` to see what it wants to delete. If the deletions are genuine, raise
`MaxDelete` in `config\links.json`. If they are not, something is wrong with the remote folder
— check it is fully mounted before letting a pass run.

**An empty folder is left behind.** It should not be — a pass removes the folders it empties,
up to but never including the link root. Two cases are left alone on purpose: a folder that
still holds a deferred file (it is revisited next pass, once the file is eligible), and an
empty folder you made by hand, which the sync model never tracked in the first place.

**A file never syncs.** Run `status`. If it says *held open*, close the application. Tally holds
company files for as long as a company is open; that is intended and protects the data.

**A conflict copy appeared.** Both versions were kept. Open both, decide, delete the one you do
not want. The next pass propagates the deletion.

Cards show a **Duplicates** button only while conflict copies exist; it expands the list within
the dashboard. Use it or CLI `status` to see which original
file each conflict copy belongs to and its paths on both sides. The list checks
both folders live when opened, including paused pairs. Copies present on both
sides appear once. The dashboard shows original and duplicate filenames directly
in rows, with **Open folder** buttons for each available local/remote copy. Explorer
opens the containing folder and selects the duplicate. A missing copy is labelled
**Not present**. Original paths
identify the original filename and do not guarantee that file still exists.
The tray warns while copies remain, using the last background pass's snapshot.
This recognizes DriveRelay's `(conflict from <provider> <timestamp>)` names;
renamed duplicates no longer appear, and ordinary duplicate content is not scanned.

**Nothing is syncing at all.** Check the tray is running and not paused, then check
`driverelay.log`. A run of passes with nothing to do logs one line an hour —
`idle: 6 pass(es) since 09:10:00, nothing to relay` — so more than an hour of complete
silence means it is not running.

## The log

At the default `INFO` level the log records what **changed**: copies, deletions, conflicts,
aborts, and links that came back unavailable. Bookkeeping that repeats every pass regardless
of whether anything happened is written at `DEBUG` and suppressed.

That includes the per-file `deferred` lines. A workbook held open by Excel or Tally is
deferred again on every pass for as long as it stays open, so naming it every ten minutes
crowds out the copies and deletes the log exists to record. The count still appears on the
link summary, and `DriveRelay status` names the individual files.

When something needs diagnosing, turn the detail back on — and back down afterwards, because
it is verbose:

```powershell
.\DriveRelay.ps1 config -LogLevel DEBUG
.\DriveRelay.ps1 config -LogLevel INFO
```

The log rotates at `LogMaxSizeMB` (default 1 MB) to `driverelay.1.log`, `driverelay.2.log`
and so on, keeping `LogKeepFiles` generations (default 3). Older history is moved aside
rather than truncated away, so roughly the last 4 MB is always available.

That bounds the log by size, not by time — a quiet link can leave a generation sitting for
months. `LogMaxAgeDays` (default 60) is the separate limit on that: once a rotated generation
is older than this, it is deleted outright regardless of how many `LogKeepFiles` allows for.
Only rotated generations are ever removed this way; the active `driverelay.log` is not.
Set it with `config -LogMaxAgeDays 60`, or `0` to turn the age limit off and rely on
`LogKeepFiles` alone, as before this existed.

## Files

| Path | |
|---|---|
| `config\links.json` | The links. Editable by hand; keep a copy first. |
| `config\excludes.txt` | Never-sync patterns, one per line |
| `state\<id>\manifest.json` | Sync baseline. **Deleting this loses history** and the next pass treats everything as new. |
| `state\lastpass.json` | Last pass summary, read by the tray |
| `driverelay.log` | Active log. Rotates to `driverelay.1.log` .. `.3.log` at 1 MB |

## Install and uninstall

```powershell
.\Install.ps1 -IntervalMinutes 10
.\Install.ps1 -NoAutoStart      # no Startup shortcut
.\Uninstall.ps1                 # keeps links and history
.\Uninstall.ps1 -AlsoRemoveSettings
```

No administrator rights, no services. Uninstall never touches files in any linked folder.
