# Rename an Event Across Athletes — Design

**Date:** 2026-10-10
**Status:** awaiting review

## Goal

A coach renames an event — its date, its title, or both — once, and every
athlete's clips of that event follow, in a Google Drive library or a local
one. If the new name is an event that already exists, the coach is asked
whether to merge into it. Nothing is ever overwritten, and no clip, analysis
or sync point is lost.

**Success:** after a rename, every clip of the event shows under the new name;
analysis done on those clips is still there; a rename interrupted halfway
(signal lost on the hill, app killed) finishes cleanly when run again.

## What was decided with the user

- **Both Drive and local libraries.**
- **Title and date can change.** The new folder name is built by
  `SortingLibrary.eventFolder(date:title:)`, the same function sorting uses,
  so a renamed event is spelled exactly like a freshly sorted one and keeps
  sorting newest-first by its ISO date.
- **Same name as an existing event → ask, never assume.** It may be a slip.
  The dialog offers **Merge**, **Choose Another Name** (back to the field,
  text kept) and **Cancel**, and shows what each side holds
  ("12 clips · 5 athletes") so the coach sees what they are merging into.
- **Approach A:** compute a plan, then run idempotent steps.

## What the codebase already gives us (measured by reading it)

- **Drive clip identity is the file id** (`RemoteFile.identity(inProvider:)`),
  so analysis, sync points and the clip cache survive any rename or move of
  folders or files in Drive. Only the library index's paths need refreshing.
- **Local clip identity is the standardised file URL** (`ClipIdentity.local`),
  but local sidecars sit **beside the footage** and are named by clip stem
  (`ClipAnalysisStore.sidecarURL`, `AlignmentTrackStore.sidecarURL` — the
  latter files a local pair in the *left* clip's folder as
  `<leftStem>--<rightStem>.<ext>`). So renaming a local event *folder* carries
  its analysis with it untouched. Only a merge, which moves individual clips,
  must move each clip's sidecars with it.
- **Event folders by layout** (`FolderConvention`):
  `eventThenAthlete` → one event folder at the top, so a rename is one
  operation; `athleteThenEvent` → one event folder under each athlete, so a
  rename is one operation per athlete and can fail partway.
- **Drive refresh today** (`ViewerModel.openRemoteLibrary`): only on opening a
  library, as a delta from the stored cursor
  (`GoogleDriveProvider.changes` → `RemoteLibraryIndex.applying`). A changed
  *file* is re-resolved and lands at its new path. A changed *folder* is used
  only as a lookup for files that changed in the same page; clips *inside* a
  renamed or moved folder are not in `changes.changed`, so they keep their old
  stored path — the sidebar shows the old event or athlete name until the
  user ticks "Rebuild library" in the Google Drive sheet. The code-side gap is
  certain; that Drive's change log does not also list the descendants of a
  renamed folder is our reading of the API, **not yet verified live**.

## Components

1. **`EventRenamePlan`** (SkiVideoCore, pure). Inputs: the library's clips,
   its layout, the old event name, the new name. Output:
   - the affected event folders (one, or one per athlete);
   - per folder, **rename** (no event of the new name at that spot) or
     **merge** (one exists);
   - per merge: clips to move, clips that collide (same file name under the
     same athlete in the target — they stay), and the sidecars that travel
     with each moved local clip;
   - the counts the merge dialog shows.
   Built from the library's *current* state, so re-planning after a partial
   run naturally yields only the remaining work.

2. **`FolderWriting` protocol** (SkiVideoCore, beside `ItemCreatable`,
   reached with `as?`): rename a folder, move a file into a folder, list a
   folder's children, and move an emptied folder to the bin.
   - **Drive:** `files.update` (`name`, or `addParents`/`removeParents`;
     `trashed: true` for the bin), always `supportsAllDrives=true`; ids are
     preserved. Write consent reuses `authorizeWrites(presenter:)` — **no new
     OAuth scope**. Errors map onto the upload's `RemoteUploadError`
     (`retryClip` → here "retry", `stopBatch` → "stop").
   - **Local:** `FileManager` moves that **never overwrite** — an existing
     destination fails the step instead.

3. **`EventRenameRunner`** (SkiVideoCore, `@MainActor`, observable). Runs the
   plan step by step. Each step checks current state first and skips what is
   already done. Publishes progress ("3 of 9") and a final summary (renamed /
   merged / clips left in place, with names). Takes its writer injected, so a
   fake stands in for tests.

4. **Refresh.**
   - **Drive:** when a change page contains any folder record (renamed or
     moved folder), `openRemoteLibrary` re-lists the library instead of
     applying the delta. Folder changes are rare, so the full listing is rare.
     This fixes renames made anywhere — Drive's web UI, another coach, or this
     feature — and the runner simply re-opens the library when it finishes.
   - A visible **Refresh** on the open library, so a coach can pick up Drive
     changes without re-opening it.
   - **Local:** the existing rescan.

5. **UI.** "Rename Event…" in the context menu of an event in the sidebar
   (Mac and iPad/iPhone). A sheet with a date picker and a title field,
   pre-filled from the current name. Rename is disabled while the name is
   unchanged or invalid. On a collision, the merge dialog above. Progress and
   the summary appear in the sheet.

## Error handling

**Before anything moves:**
- Title empty or containing characters a folder cannot hold → refused inline.
- Drive: `authorizeWrites` first; a 403 "no edit access" stops before any step.
- Local: a read-only location (locked card, Files location without write
  access) is refused up front.
- Comparison window or a sorting session open → refused ("Close the
  comparison first"): they hold clip paths a rename would invalidate.

**During the run:**
- Retryable failure (dropped connection, expired session, any unclassified
  error) → stop with "Renamed 4 of 9 — <reason>. Try again".
- Stop-class failure (403, signed out) → stop with that reason.
- After any stop the library is refreshed immediately, so the sidebar honestly
  shows which athletes are under which name. "Try again" re-plans from that
  state.
- Merge collisions are never overwritten; they stay in the old event and are
  listed in the summary.

**After a merge:**
- An old event folder left empty is binned on Drive (recoverable for 30 days)
  and deleted locally — but only after re-checking, at that moment, that it is
  empty. A folder still holding anything (collisions, non-video files) stays.

**Selection:** a clip open in the viewer that belonged to the renamed event is
re-selected under its new name after the refresh.

## Out of scope

- **The upload tray does not follow renames.** Clips already sorted on a
  device keep the old event name on disk; uploaded after a rename, they create
  an old-named folder again.
- **Concurrent renames** by two coaches: the per-step state checks prevent
  corruption, and the second coach sees the changed state; there is no lock.
- Renaming athletes (a natural sibling feature, not this one).

## Testing

**Unit (Mac, `--filter SkiVideoCoreTests`):**
- `EventRenamePlan`: both layouts; rename vs merge; collisions; sidecars
  travelling with a moved local clip; re-planning after a partial run yields
  only the remainder; dialog counts.
- `EventRenameRunner` with a fake writer that records operations: skips
  completed steps; a retryable failure stops with correct progress; a stop
  failure stops; a second run finishes the job; a non-empty old folder is
  never binned; the emptiness check runs just before binning.
- Local writer on real temporary directories: never overwrites; sidecars move
  with the clip; a local alignment pair still resolves after a merge.
- Drive writer against the fake transport: exact `files.update` requests
  (name / parents / trashed), `supportsAllDrives=true` on every one, error
  mapping.
- Refresh: a change page with a folder record triggers a full re-list, one
  without keeps the delta path, and clips under a renamed folder come out
  with their new path.

**UI:** rename an event against the fake Drive and see the sidebar update;
trigger the merge dialog and choose "Choose Another Name". Same seam pattern
as `PhotosToDriveUITests`.

**By hand on real data:**
- rename an event in the real club Drive (both layouts if available) and
  check it in Drive's web UI;
- merge two spellings of one day;
- rename a folder in Drive's web UI and confirm the app picks it up — the
  live check for the unverified change-log assumption above.

## Sequencing

Starts after the photos-to-club-drive branch is finished (its UI-test fix,
final review and full test run), on its own branch.
