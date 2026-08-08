# Current state

Everything here was measured on the development machine, not assumed. Dates are when the
measurement was taken.

Volumes and folder names are generalised; the measured behaviour — attribute transitions,
hydration effects, delete recovery — is reported exactly as observed, because that is what
the design rests on.

## Machine

| | |
|---|---|
| OS | Windows 11 Pro, build 26100 |
| PowerShell | Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 |
| Cloud client | OneDrive, `C:\Program Files\Microsoft OneDrive\OneDrive.exe` |
| Google Drive | Not installed — no client, no process, no mounted drive |

## The sync root (2026-08-07, before migration)

The real OneDrive sync root is `D:\OneDrive`, confirmed from
`HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts\Personal\UserFolder` — worth knowing, because the
sync root is frequently not where you assume it is.

The root held six figures of files, of which **78% were cloud-only placeholders**. That ratio
is the number that matters: it is why change detection must never read file content, and why
a single `Get-FileHash` sweep would have been catastrophic rather than merely slow.

`%USERPROFILE%\OneDrive` was a stale husk from a previous configuration — 1 file, ~0 MB. It is
not the sync root and nothing uses it. Check before assuming.

## Known Folder Move

| Folder | Redirected to | In sync scope |
|---|---|---|
| Documents | `D:\OneDrive\Documents` | yes |
| Desktop | `D:\OneDrive\Desktop` | yes |
| Pictures | `D:\OneDrive\Pictures` | yes |
| Downloads | `%USERPROFILE%\Downloads` | no |

**Not yet changed.** Anything saved to Desktop or Documents still lands inside the sync root.
Redirecting these is optional now that the client stays running, but it is the reason Excel is
still slow in those particular folders.

## First migration (2026-08-07)

Three links were seeded from the OneDrive side — a general work folder, a personal folder and
an accounting-database folder. Roughly 14,300 files, ~18 GB nominal. Result: **0 deferred,
0 conflicts, 0 failures.** All three were fully hydrated beforehand, so nothing had to be
downloaded.

Net disk cost was **about 2 GB, not 18** — the local copies landed while the remote side
dehydrated, so the space came back as it went. This is the single most useful thing to know
before a first seed: the peak is far lower than the arithmetic suggests, but it is not zero,
and the order is not guaranteed.

A few hundred zero-length files appeared in the copies. They were zero-length at source too —
the counts matched exactly on both sides — mostly empty error-report logs from an earlier
data migration. Not an error, but worth checking rather than assuming.

## Placeholder behaviour, measured

Written to a throwaway file in `D:\OneDrive` and observed:

```
0x20        fresh local file             no cloud flags
0x100020    attrib +U -P, not uploaded   UNPINNED    <- request only, refused to dehydrate
0x501620    after upload completed       Offline, RecallOnDataAccess, UNPINNED
0x80420     attrib +P -U                 PINNED      <- content pulled back
```

Two findings the whole design rests on:

1. **UNPINNED is a request; Offline is the receipt.** OneDrive would not dehydrate the file
   while the service lacked its content. So dehydration cannot lose data, and "did Offline
   appear?" is a trustworthy upload confirmation.
2. **Reading content hydrates.** `Get-Item` metadata left the file `Offline`; a single
   `Get-FileHash` cleared it — a full download. Change detection therefore uses size and
   timestamp only. Hashing would have quietly pulled down every placeholder in the root on the
   first run — on this machine, well over a hundred gigabytes.

## Delete recovery, measured

| Deleting | Recycle Bin? | Recovery |
|---|---|---|
| Ordinary file with content | yes (verified) | local Recycle Bin |
| Dehydrated placeholder | **no** | the cloud service's online recycle bin |

A placeholder has no local content, so the Recycle Bin has nothing to store. The live links on
this machine all have `HydrateBeforeDelete` enabled, which downloads a cloud-only file before
deleting it so the Recycle Bin keeps a real copy. It costs a download per deleted file, which
is why it is not the default.

## Related

- [03-architecture.md](03-architecture.md)
- [05-runbook.md](05-runbook.md)
