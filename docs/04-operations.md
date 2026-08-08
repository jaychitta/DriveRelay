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

DriveRelay.ps1 start                              launches tray agent
DriveRelay.ps1 stop                               stops running tray agent
DriveRelay.ps1 ui                                 opens dashboard UI
DriveRelay.ps1 log                                opens log file

DriveRelay.ps1 install   [-IntervalMinutes 10]    registers startup & shortcuts
DriveRelay.ps1 uninstall [-AlsoRemoveSettings]    removes shortcuts & tasks
```

`-Remote` is any folder — OneDrive, Google Drive, Dropbox, a network share, another disk.
`-OneDrive` still works as an alias.

### Adding a folder safely

```powershell
.\DriveRelay.ps1 add -Local "D:\Work\Foo" -Remote "D:\OneDrive\Foo" -Seed Remote -HydrateBeforeDelete
.\DriveRelay.ps1 check -Id Foo -Detailed
.\DriveRelay.ps1 sync  -Id Foo -WhatIf
.\DriveRelay.ps1 sync  -Id Foo
```

`check` (or `compare`) and `-WhatIf` both write nothing. Use them on anything you care about.

## Reading a compare report

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

**A file never syncs.** Run `status`. If it says *held open*, close the application. Tally holds
company files for as long as a company is open; that is intended and protects the data.

**A conflict copy appeared.** Both versions were kept. Open both, decide, delete the one you do
not want. The next pass propagates the deletion.

**Nothing is syncing at all.** Check the tray is running and not paused, then check
`driverelay.log`. A pass with nothing to do still logs `pass ran with no enabled links` or
`pass finished`, so silence means it is not running.

## Files

| Path | |
|---|---|
| `config\links.json` | The links. Editable by hand; keep a copy first. |
| `config\excludes.txt` | Never-sync patterns, one per line |
| `state\<id>\manifest.json` | Sync baseline. **Deleting this loses history** and the next pass treats everything as new. |
| `state\lastpass.json` | Last pass summary, read by the tray |
| `driverelay.log` | Trimmed to the last 2000 lines at 1 MB |

## Install and uninstall

```powershell
.\Install.ps1 -IntervalMinutes 10
.\Install.ps1 -NoAutoStart      # no Startup shortcut
.\Uninstall.ps1                 # keeps links and history
.\Uninstall.ps1 -AlsoRemoveSettings
```

No administrator rights, no services. Uninstall never touches files in any linked folder.
