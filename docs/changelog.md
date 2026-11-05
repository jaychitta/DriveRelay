# Changelog

What changed in DriveRelay (formerly SyncOrchestrator), newest first, in plain
words: what changed, why, and what was checked. Technical detail lives in the
other documents in `docs/`.

Shortened on 2026-11-05 at Jay's request. The same day, also at Jay's
request, the git history (23 versions, 8 Aug to 5 Nov 2026) was replaced by a
single version, here and on GitHub, with no backup kept. This changelog is
now the only record of earlier changes; their fuller wording no longer
exists.

## Still open

- **Tray "Sync now" while paused** (07-audit item 5). Jay ran the log viewer
  and "Start with Windows" checks on 2026-11-05 and both worked. On pausing,
  he found the icon "most of the times shows the paused look". Cause found:
  the tray has no icon of its own for "paused"; it uses the same amber
  warning icon as "needs attention", OneDrive not running, duplicates and
  deletion conflicts. So the amber icon shows most of the time, and paused
  cannot be told apart from the others. Fixed the same day (see below); steps
  2-4 of the check ("Sync now" runs while paused, the icon stays paused,
  Resume restores it) are still to be run by Jay with the new icon. The "last
  sync failed" and "unreachable folder" cases are skipped, because testing
  them would mean breaking a live link.

## 2026-11-05

- **Second code audit** of every script, written up in
  [07-audit.md](07-audit.md). All 31 findings were fixed. The main ones:
  - A folder that cannot be fully listed now stops that link. Before, the
    missing files could look like deletions.
  - Each delete is re-checked just before it happens.
  - Edits made during a sync are no longer lost.
  - Seeding (the first sync of a link) keeps the replaced copy of any file it
    overwrites.
  - Deletes on drives with no Recycle Bin are kept in a hidden holding folder
    rather than being deleted for good.
  - Folder shortcuts (junctions) are not followed.
  - A damaged history file is repaired from its backup, or the link stops.
  - Settings are saved safely when two programs change them at the same time.
  - The tray no longer freezes while it checks folders.
  - "Sync now" works while syncing is paused.
- **Fix found on the first Windows run:** saving settings or the last-sync
  summary a second time always failed. From 12:40 that day each sync logged
  that it could not write its summary. Copying files was not affected.
- **Installed from source** at Jay's request. The program and its shortcuts
  were rebuilt; links, settings and history were left as they were.
- **Dashboard, Review button:** deletion conflicts now open as a list inside
  the card, the same way Duplicates does. Each row has buttons to open the
  surviving copy and the place it was deleted from. Jay confirmed it works.
- **Dashboard opens without "Checking folders...".** Jay asked why it always
  said "checking". The answer: it re-checked every folder from scratch on each
  opening, about 20 seconds, and showed nothing until all were done. There was
  never a 10-minute limit; 10 minutes is how often the sync runs. Now, for a
  link synced in the last 10 minutes, the dashboard reuses that sync's lists
  and checks only whether each drive and OneDrive are available. The opening
  check went from about 20 seconds to 0.1 seconds. A conflict you have just
  resolved can stay on the card until the next sync; "Sync now" clears it
  sooner.
- **History kept only where it has a use** (agreed with Jay):
  - Removing a link sends its history to the Recycle Bin. If a sync is
    running at the time, the next sync does it.
  - History set aside when a link is added again goes to the Recycle Bin
    after 30 days.
  - Only folders holding nothing but history are removed, and nothing at all
    if the list of links is missing or empty.
  - Nothing is ever deleted outright.
  - Live links keep their history plus one backup. Logs are kept 60 days.
- **Tidied, to the Recycle Bin:** the old Jay-Suite history (a link removed
  in September) and six leftover files from past work.
- **Rewrite plan withdrawn.** The saved plan to rebuild DriveRelay in C#/.NET
  (saved 26 October, never started) was removed on advice to keep the current
  program. With the history reset the same day, its text no longer exists.
- **No more lost log lines.** When the tray, the dashboard and a sync wrote
  to the log at the same moment, lines could be lost. They now take turns. In
  the same test, two programs writing 300 lines each kept 68 of 600 lines with
  the old code and all 600 with the new.
- **Paused has its own tray icon.** Pausing used to show the same amber
  warning icon as "needs attention", so the tray looked paused most of the
  time. At Jay's request, paused now turns the whole icon grey with a pause
  sign; amber is kept for things that need you. The tray was restarted at
  16:37 (after the running sync finished) so it uses the new icon.
- **Open items closed with Jay:** the network-drive Recycle Bin check is not
  applicable (all links are on drive D:); the code style checker was dropped
  (correctness is covered by the tests and two audits); Jay checked the
  dashboard's faster opening in the real window and it is good; Jay reports
  Task Manager names the startup app "Drive Relay" (no longer a generic
  script host), so the 2026-10-13 check is closed. Jay accepted the slower
  folder walk on Office (about 3 seconds, against 0.4 before) as the cost of
  not following folder shortcuts.
- **Checked:** the automatic tests pass on Windows, 316 of 316, run on a
  scratch copy of the program. The tests cannot run while a real sync is
  running, because they share its lock. The tray and dashboard windows are not
  covered by the tests (see "Still open").

## 2026-10-26

- **Installer withdrawn.** At Jay's direction the Inno Setup installer and its
  test were removed. Setting up from the folder (`Setup.cmd`) still works.
- **Housekeeping:** about 19 MB of old build output removed; past packages and
  their check records kept under `release\`.
- **Documents** brought in line with the program.
- **Checked:** 232 tests passed; clean-up checks 19 passed.

## 2026-10-22

- Build output is cleared before and after each build, and only DriveRelay's
  own build folders can be removed. The real installer check could not run
  (Inno Setup not installed); this was later superseded by withdrawing it.

## 2026-10-19

- Checked that the folder matched the GitHub copy. No changes.

## 2026-10-18

- Current work saved to GitHub as a backup. Client names were removed from
  the notes first; links, settings, history and logs stay out of git.
- **Checked:** 234 tests passed.

## 2026-10-15

- **Moves and renames are relayed.** A file moved or renamed on one side is
  moved on the other, without copying it again. This happens only when
  Windows' own file identity proves it is the same file; a matching name, size
  or date alone is never enough. Empty folders and changes of letter case only
  are still not handled.
- **Windows installer** added (later withdrawn, 2026-10-26).
- **Checked:** 232 tests passed. Real OneDrive placeholder moves were not
  tested.

## 2026-10-13

- **Dashboard no longer freezes on opening.** Folder checks moved to the
  background; cards say "Checking folders..." until done (about 19 seconds).
- **The startup app shows as "DriveRelay"** in Windows, via a small launcher
  program, instead of a generic script host. Task Manager's label still needs
  a look.
- **Logs reviewed** for the October 7 duplicates: those duplicates were gone
  on both sides, and deletions were reaching the OneDrive folder.
- Tray started at Jay's request.
- **Checked:** 163 tests passed.

## 2026-10-08

- **Deletion conflicts.** When a file is deleted on one side but the other
  copy has changed, DriveRelay no longer brings the deleted file back. It
  leaves both sides as they are and lists the file for review. This came from
  a deleted Office subfolder that came back; why the earlier sync chose to
  copy it could not be established from the logs.
- A copy is not made if its destination was deleted during a long sync.
- A single duplicate now shows its Duplicates button.
- **Checked:** 154 tests passed.

## 2026-10-07

- **Duplicates list.** Conflict copies are listed in the dashboard and in
  `status`, with buttons to open each one. Only DriveRelay's own naming of
  conflict copies is recognised; a renamed copy is not.
- A stopped sync shows its reason on the card.
- Fixed: file dates read back from history were shifted by the time zone.

## 2026-09-08

- **Logs kept for 60 days at most**, at Jay's request, as well as the size
  limit. A setting meant to control this had no effect at first; caught by the
  tests before release.

## 2026-08-12

- **Shorter log**, at Jay's request ("log is becoming too long"). Two thirds
  of it was quiet syncs that changed nothing; these now show as one line an
  hour. Full detail can be switched back on (`LogLevel DEBUG`). Old logs
  rotate into numbered files.
- Fixed: several `config` and `add` options were silently ignored.
- Corrected the command list in the operations guide (four listed commands
  never existed).

## 2026-08-11

- **Empty folders removed.** Folders emptied by a sync are removed on the
  other side too. Empty folders you made yourself are left alone.

## 2026-08-08

- **First audit** ([06-audit.md](06-audit.md)); all 12 findings fixed. Among
  them: two links can no longer share a folder; settings changes during a
  sync are no longer lost; pausing is remembered after a restart.
- **Drive and OneDrive checks.** A drive that is not connected, a deleted
  folder, and OneDrive not running are told apart and reported on the tray
  and dashboard. When OneDrive is stopped, local changes still copy across.
- **Double-click setup** (`Setup.cmd`, `Uninstall.cmd`), README, licence,
  first publication to git. Private links, settings and history are kept out
  of git.
- **Checked:** 67 tests passed by the end of the day.

## 2026-08-07

- **Renamed from SyncOrchestrator to DriveRelay**, with simpler commands
  (`add`, `list`, `rm`, `pause`, `resume`, `check`, `sync`, `status`, `start`,
  `stop`).
- Tray icon, dark dashboard, central settings, per-link settings and the first
  17 automatic tests added. The folder can now be moved or renamed.
