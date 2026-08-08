# DriveRelay code audit

**Date:** 2026-08-08
**Scope:** every `.ps1` and `.vbs` in the repository at the time of writing — 18 PowerShell
files, 3,679 lines, plus configuration, assets and the test harness.
**Performed by:** Claude (Opus 5) via Claude Code, commissioned by Jayadheer Chitta.
**Standing instruction from the owner:** report findings for triage rather than quietly
fixing them, so the decisions about what to change stay with the person who decided what
this tool must never do.

Findings below were reached by reading the source and, where a claim could be tested,
by reproducing the behaviour in a scratch directory rather than asserting it from the
code alone. Each finding says which method was used.

---

## Method

| Check | Result |
| --- | --- |
| Parse check, all 18 `.ps1` files (`[Parser]::ParseFile`) | clean, no syntax errors |
| Existing regression suite (`tests/Test-DriveRelay.ps1`) | 17 passed, 0 failed |
| PSScriptAnalyzer | not installed on this machine; not run |
| Runtime reproduction of engine behaviour | 2 scenarios built and executed (findings 1, 2) |
| Production log review (`driverelay.log`) | reviewed; one historical failure explained below |

No sync pass was run against the live links during this audit, and no file in any
linked folder was read, copied or deleted.

---

## What the design gets right

These are load-bearing and worth not regressing:

- **Copies are atomic.** `Copy-FileAtomic` writes to `<name>.driverelay.tmp` and moves
  into place, and the temp suffix matches the shipped `*.tmp` exclude, so a crash
  mid-copy leaves something the next snapshot ignores rather than a truncated file that
  looks complete.
- **Deletion requires proof.** `Compare-LinkState` only ever proposes a delete when the
  manifest shows the file existed at the last pass. Absence alone never deletes — which
  is the difference between a sync tool and a data-loss incident.
- **The delete cap is checked before anything is applied.** `Invoke-LinkSync` counts
  proposed deletions and aborts the whole link before the first write, so a pass that
  looks like mass deletion never gets halfway through.
- **Cloud files are never hashed.** Change detection is size plus last-write-time only.
  The comment block in `Hydration.ps1` records the measurement that forced this
  (`Get-FileHash` clears Offline, i.e. downloads the file). Enumeration is metadata only.
- **Dehydration is confirmed, not assumed.** UNPINNED is treated as a request and the
  Offline attribute as the receipt, so a file is never considered uploaded on faith.
- **Passes cannot stack.** A named mutex (`Global\DriveRelayPass`) makes a second pass
  step aside, including the abandoned-mutex case after a crash.
- **`-WhatIf` reaches the bottom.** Every writing function is `SupportsShouldProcess`.
- **Failed and deferred files keep their old manifest entry**, so the next pass compares
  against the same baseline instead of inventing a conflict.

---

## Findings

### 1. `DeleteRemote` failures in the production log — already fixed in source

**Severity:** resolved, but with a live consequence.

`driverelay.log` records 24 consecutive failures at 2026-08-07 17:36:18:

```
[ERROR] action DeleteRemote failed for <path redacted>.pdf:
        Cannot bind argument to parameter 'Path' because it is an empty string.
```

This was the `OneDrive`→`Remote` property rename in the SyncOrchestrator→DriveRelay
migration: the call site still read a property that no longer existed, so a `$null`
reached a mandatory `[string]` parameter. `lib/Actions.ps1` was last modified at 17:50,
fourteen minutes *after* those log lines, and the current source reads
`$item.Remote.FullPath` correctly.

**Verified by reproduction.** A scratch link was built with a file present only on the
remote side and recorded unchanged in the manifest — the exact `DeleteRemote`
classification. Current source result: `Applied=1 Deleted=1 Failed=0`. The bug is gone.

**Live consequence, and the reason this is listed at all:** those 24 deletions were never
applied, so they are still outstanding. The next pass over the `Office` link will now
succeed at deleting those 24 files from `D:\OneDrive\Office`. That is the correct
behaviour — they were deleted locally and the manifest proves it — but it will happen on
the next pass rather than being a no-op, and `HydrateBeforeDelete` is on for that link,
so each will be pulled down before going to the Recycle Bin. Run
`DriveRelay check Office` first if you want to see the list before it happens.

The `LastResult` string stored in `links.json` (`failed 24`) is stale for the same reason
and will correct itself on the next pass.

---

### 2. Link overlap validation misses the cross-side case

**Severity:** medium. **Location:** `lib/Registry.ps1:129-141`.

`Add-Link` rejects a new link whose *local* side overlaps an existing *local* side, and
whose *remote* side overlaps an existing *remote* side. It never compares the new local
against an existing remote, or the new remote against an existing local.

So a chain is accepted: register `A ↔ B`, then register `B ↔ C`. Folder `B` is now the
remote side of one link and the local side of another. Two links drive the same tree,
each with its own manifest, and a file arriving in `A` propagates to `B` on one pass and
to `C` on another — with the two manifests disagreeing about what the baseline was.

**Verified by reproduction:**

```
link 1 registered: A <-> B
link 2 registered: B <-> C   <-- ACCEPTED (chain: B is both remote and local)
```

The self-overlap guard at the top of the function (`Test-PathOverlap -A $Local -B $Remote`)
already establishes that the two sides of a *single* link must not contain one another;
the loop over existing links just doesn't apply the same rule across links.

**Fix:** in the existing-links loop, test all four combinations rather than two.

---

### 3. Dashboard double-click handlers read a variable that is out of scope

**Severity:** medium (broken feature, not a data risk). **Location:** `DriveRelayUI.ps1:738-740`.

```powershell
$card.Add_DoubleClick({ Start-Process explorer.exe $Link.LocalPath })
```

`$Link` is a parameter of `New-LinkCard`. The handler runs later, from the WinForms
message loop, long after `New-LinkCard` has returned — PowerShell does not capture the
defining scope automatically, so `$Link` resolves to `$null` and the double-click either
errors or opens the wrong folder.

The same function already works around this correctly for the Edit and Pause buttons,
which stash `$Link.Id` in `$this.Tag` and re-read the registry inside the handler. The
three double-click handlers were simply missed.

**Fix:** stash the path in `.Tag`, or append `.GetNewClosure()` to the handler.

---

### 4. Saving global settings silently discards every per-link override

**Severity:** medium (surprising data loss, of configuration). **Location:** `DriveRelayUI.ps1:374-379`.

`Show-SettingsDialog`'s save handler loops over every registered link and force-writes the
new global `SettleMinutes` and `MaxDelete` onto each one:

```powershell
foreach ($l in $links) {
    if ($l.SettleMinutes -ne $newSettings.SettleMinutes -or $l.MaxDelete -ne $newSettings.MaxDelete) {
        Set-LinkSettings -Id $l.Id -SettleMinutes ... -MaxDelete ...
    }
}
```

The condition reads as a guard but is the opposite of one: it fires precisely on the links
that have been customised. `Show-LinkEditDialog` exists specifically to let a link differ
from the global default — a Tally link wanting a longer settle window, say — and opening
the global Settings dialog and pressing Save wipes that, with no warning and no mention in
the dialog text.

**Fix:** either drop the propagation loop, or make it explicit — a "apply to all existing
links" checkbox, default off.

---

### 5. `links.json` is read-modify-written with no lock

**Severity:** medium-low. **Location:** `lib/Registry.ps1:226-246`, `lib/Pass.ps1:137-145`.

`Update-LinkState` re-reads the whole registry, mutates one link's `LastRun`/`LastResult`,
and rewrites the entire file — once per link, per pass. The dashboard writes the same file
whenever you press Pause, Edit or Add.

The pass mutex serialises passes against each other, but nothing serialises a pass against
the UI. Press Pause while a pass is committing and one of the two writes is lost — either
the pause is forgotten, or the pass results are.

The individual writes are at least atomic (temp-then-move), so the file is never left
corrupt; only whole updates are lost. That is why this is medium-low rather than higher.

**Fix:** hold a short named mutex around read-modify-write in `Save-LinkRegistry`.

---

### 6. `Install.ps1` misreports the sync interval it just configured

**Severity:** low (cosmetic, but it misinforms). **Location:** `Install.ps1:147`.

```powershell
Write-Host "Installed. A pass runs every $IntervalMinutes minute(s) while you are signed in."
```

`$IntervalMinutes` is the parameter's default of `10`. The script only writes that value
into settings when it was explicitly passed (`$PSBoundParameters.ContainsKey`), so a user
who previously set 30 minutes reinstalls, keeps 30, and is told it is 10.

**Fix:** report `$appSettings.IntervalMinutes` — the value actually in effect.

---

### 7. The tray's Pause is not persisted and not shared

**Severity:** low. **Location:** `DriveRelayTray.ps1:239-253`.

"Pause syncing" sets `$script:Paused` in the tray process only. It is not written to
settings, so restarting the tray — or a reboot — silently resumes syncing. It is also
invisible to the dashboard, which reads per-link `Enabled` flags and will show every link
as active while the tray is globally paused.

For a control whose entire purpose is "stop touching my files for a bit", surviving a
reboot is the reasonable expectation.

---

### 8. Concurrent writers to one log file drop lines

**Severity:** low. **Location:** `lib/Logging.ps1:44`.

The tray, the dashboard and the child CLI process all `Add-Content` to `driverelay.log`.
`Add-Content` takes a write lock; a collision throws, and `Write-Log`'s catch block
swallows it by design ("logging must never take the caller down"). The design decision is
right; the consequence is that log lines are dropped silently under contention, which
matters when the log is the primary forensic record for a sync tool.

The 1 MB rotation has the same race: two processes can rotate at once.

**Fix:** a retry loop of two or three attempts with a short backoff would recover almost
all of these without changing the never-throw guarantee.

---

### 9. `Get-LinkCount` reports 1 for an unreadable registry

**Severity:** low. **Location:** `DriveRelayTray.ps1:94-103`.

If `links.json` parses to a non-array the function returns `1` unconditionally, so a
single-object file and a malformed one both display as "1 link(s) ready". Only the tray
tooltip is affected — no engine behaviour reads this.

---

### 10. The test suite does not cover the sync engine

**Severity:** low as written, but it is the gap that matters most.

`tests/Test-DriveRelay.ps1` is 17 assertions across `Settings.ps1`, `Registry.ps1`,
`Icons.ps1`, and one CLI smoke test. All pass. None of them touch:

- `Compare-LinkState` — the classification table that decides copy vs. delete vs. conflict
- the `MaxDelete` abort path
- `Invoke-ConflictFork` — the both-sides-changed case
- manifest write/read round-tripping, including the empty-array and single-entry JSON
  shapes the code has explicit workarounds for

That is the code that can destroy data, and it is the code with no automated coverage.
Both reproductions written for this audit (findings 1 and 2) are exactly the shape such
tests would take — a scratch link in a temp folder, a hand-written manifest, one assertion
on the resulting classification. They are cheap to write and would have caught finding 1
before it reached a live link.

---

### 11. `OneDriveGate` cannot resume on any day but the one it started

**Severity:** low, and arguably by design. **Location:** `OneDriveGate.ps1:143`.

`$resumeAt = $scriptStart.Date.Add($resumeSpan)` fixes the resume moment to the start
date. The script is documented as per-boot ("restarting your machine begins the cycle
again"), so on a machine rebooted daily this is correct. On a machine left running for
days, OneDrive resumes once on day one and the gate never blocks again — `$resumed` latches
true permanently. Worth a line in the header comment, since the failure is silent.

---

### 12. Repository hygiene — personal data in the working folder

**Severity:** high *for publication*, not a defect in the software.

The working folder accumulates files that must not be published:

| Path | Contains |
| --- | --- |
| `config/links.json` | real local and cloud paths |
| `driverelay.log`, `onedrivegate.log` | client names and document filenames from every synced folder |
| `state/*/manifest.json` | a complete file listing of every linked folder |
| `config/settings.json` | no personal data, but rewritten on every run |

Addressed as part of this work: `.gitignore` now excludes all of the above, and
`config/links.example.json` / `config/settings.example.json` ship in their place. Both
files are recreated automatically on first run, so nothing breaks by their absence.

---

## Summary

| # | Finding | Severity | Verified how |
| --- | --- | --- | --- |
| 1 | `DeleteRemote` empty-path failure | resolved (24 deletes now pending) | reproduction |
| 2 | Cross-side link overlap accepted | medium | reproduction |
| 3 | Dashboard double-click reads dead scope | medium | source |
| 4 | Global save wipes per-link overrides | medium | source |
| 5 | Unsynchronised `links.json` writes | medium-low | source |
| 6 | Installer misreports interval | low | source |
| 7 | Tray pause not persisted | low | source |
| 8 | Log lines dropped under contention | low | source |
| 9 | `Get-LinkCount` returns 1 on garbage | low | source |
| 10 | No engine test coverage | low, highest leverage | test run |
| 11 | `OneDriveGate` single-day resume | low | source |
| 12 | Personal data in working folder | high for publication | file review |

**Nothing in findings 2–11 was changed by this audit.** They are reported for the owner to
triage. Only finding 12 was acted on, because it blocked the requested publication.

The engine's safety design is genuinely careful — the manifest-gated deletion, the
pre-apply delete cap and the never-hash-a-placeholder rule are the three decisions that
matter most, and all three are right. The weakest point is not the design but the absence
of tests around it (finding 10): the one bug that did reach a live link, finding 1, was a
mechanical rename error of exactly the kind a classification test catches instantly.
