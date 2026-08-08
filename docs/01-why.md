# Why this exists

## The problem

Working files lived inside `D:\OneDrive`, the active OneDrive sync root. Every filesystem
operation there passes through OneDrive's cloud filter driver (`cldflt`), which reconciles
namespace changes with the service before releasing the handle.

The effect in daily use:

- Create a folder, rename it, open it immediately — it stalls for seconds. The rename is not
  just a rename; it is a namespace change the sync engine wants to agree with the service
  about first.
- Excel is worse. Its save sequence is write-temp, rename, replace-original. That is three
  trips through the filter driver per save.

This is not a setting that can be tuned. The filter driver is not a bug in the Files
On-Demand model — it *is* the model. Anything inside a sync root pays the toll.

## The second problem

Several accounting and tax database applications kept their data inside that root — Tally
Prime among them, along with shared company files and the working data of a few tax-filing
packages. These are live database files with active locks. A sync engine reading a file
mid-write is a known route to corrupted company data, and a sync engine *holding* a lock is a
known route to Tally refusing to open a company at all.

## The fix, and why it is shaped this way

Work happens in plain NTFS folders no sync client knows about — `D:\Office`, `D:\Tally Prime`
and the like are ordinary directories, outside any sync root. No filter driver, no
placeholders, native speed.

A background orchestrator then does what you would otherwise do by hand: copy changed files
between the working folder and its paired folder in the cloud drive. The cloud client uploads
from its side exactly as it always did.

**The slowness is not removed. It is delegated.** A background process absorbs the filter-driver
latency instead of you waiting on it. That is the whole idea, and it is why this design beats
trying to make the sync root faster: you cannot, but you can stop being the one who waits.

## Why not just use rclone, or the cloud client's own settings

- **Cloud client settings** cannot help. Every commercial client's premise is "the folder *is*
  the cloud". Asking for a working copy the driver cannot reach contradicts that premise.
- **rclone over the API** was considered and rejected. It would mean retiring the desktop
  client and holding cloud credentials. This design has no credentials, makes no network
  calls, and leaves the client doing the job it is good at.

## What `OneDriveGate.ps1` was

An earlier attempt that shut down `OneDrive.exe` on a schedule. It treated *when* sync
interferes rather than *where* files live, so files stayed in the sync root and sync resumed
later. It is kept in the repository but is no longer needed.

## Related

- [02-current-state.md](02-current-state.md) — what was measured on this machine
- [03-architecture.md](03-architecture.md) — how it works
