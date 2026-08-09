# Cmd+Arrow slow motion, matching comparison hotkeys, and event grouping

Date: 2026-08-09

Three changes, in one spec because the first two share a mechanism and the
third is independent but small.

1. Slow motion moves off long-press and onto Cmd+Arrow.
2. The comparison window gets the same arrow hotkeys as the viewer.
3. A folder holding several events, each holding athletes, groups by event
   instead of merging athletes across events.

## Part 1 — Hotkeys

### Behaviour

| Key | Viewer | Comparison |
| --- | --- | --- |
| `←` / `→` | seek −1 s / +1 s on key-**down** | same, routed through `applyTransport(.back1/.forward1)` |
| `←` / `→` twice within 0.38 s | seek −5 s / +5 s | same |
| `⌘←` / `⌘→` held | play at 0.35× in that direction while held | same, over the players `target` names |
| `⌘←` / `⌘→` released | stop, restore the pre-hold rate | same |
| `Space` | play/pause | play/pause |

Long-press on a bare arrow no longer means anything: the 0.22 s tap-vs-hold
race disappears, and a plain arrow seeks immediately on key-down rather than
waiting for the release to find out whether it was a hold.

The double-tap → ±5 s rule is kept as it stands today, including its 0.38 s
window and the injected `now` closure the tests drive it with.

### `SlowMotionHold` (new, `Sources/SkiVideoCore/SlowMotionHold.swift`)

One direction of held slow playback over a set of players, and nothing else:

```swift
@MainActor final class SlowMotionHold {
    func begin(_ direction: ScrubDirection, players: [AVPlayer])
    func end()
    var isActive: Bool { get }
}
```

- **Forward**: `playImmediately(atRate: 0.35)` on every player.
- **Backward**: `-0.35` when *every* player reports `canPlayReverse`;
  otherwise the fallback the viewer already has — pause, plus a single 0.08 s
  repeating timer that seeks every player back 0.08 s in step. All-or-nothing
  on purpose: a synced pair with one side running natively and the other
  stepping would drift apart, which is precisely what the comparison window
  exists to prevent.
- **`end()`** restores each player's pre-hold rate (or leaves it paused if it
  was paused), invalidates the timer, and is idempotent. It is safe to call
  from app-resign, window close, and clip change, and those paths do call it.

The body is lifted from `ViewerModel.startHold` / `resumeHeldPlayback` /
`pauseHeldPlayback` / `endArrow`, which lose their copies. Its `begin` takes
the players as an argument rather than holding a reference, so the comparison
window can hand it one side, the other, or both from one call site.

### Intents (`Seams.swift`)

`.scrubBegan` / `.scrubEnded` are replaced by:

```swift
case seek(ScrubDirection)              // plain arrow, key-down
case slowMotionBegan(ScrubDirection)   // ⌘+arrow, key-down
case slowMotionEnded                   // ⌘+arrow key-up, ⌘ released, focus lost
```

`.slowMotionEnded` carries no direction and no `performTap`: releasing a slow
hold is one action with one meaning, unlike the old `.scrubEnded`, whose
`performTap` existed only to distinguish a release (which should seek) from a
cancellation (which should not). Seeks are now their own intent, so that
distinction has nothing left to express.

`SortingModel.handle` renames its two `.scrubBegan(x)` cases to `.seek(x)` and
ignores the new pair. The sorting window binds no ⌘ chords, so its
`arrowsRepeat` fast-scan at ±5 s is unaffected.

### `AppKitInputSource`

- The modifier gate (today: reject any event carrying ⌘/⌃/⌥) becomes: reject
  ⌃/⌥ always; treat ⌘ as meaningful on keyCodes 123/124 only, and reject it
  everywhere else. Space, the clip arrows and the page keys keep refusing
  modified events.
- Bare `←`/`→` key-down emits `.seek`. Nothing is emitted on their key-up.
- `⌘←`/`⌘→` key-down emits `.slowMotionBegan` and records `heldDirection`.
- The hold ends — `.slowMotionEnded`, `heldDirection` cleared — on any of: the
  arrow's key-up, a `flagsChanged` that drops ⌘ while the arrow is still down,
  `setEnabled(false)`, and `NSApplication.didResignActiveNotification`.
- `heldDirection` keys off the keyCode alone and never re-checks the modifier.
  An operator who lifts ⌘ before the arrow must still get a clean release, and
  the key-up for that arrow carries no ⌘ flag by then.
- The existing rule that a consumed key-down is always matched by a consumed
  key-up is preserved, so no half-handled arrow leaks to the app.
- The text-field exemption is unchanged: while an `NSTextView` is first
  responder the monitor bails before any of this, which also leaves the
  system's ⌘← / ⌘→ line-navigation intact inside the athlete search field.

### `ViewerModel`

`beginArrow`, `endArrow`, `holdWorkItem`, `holdStarted`, `holdPausedManually`,
`wasPlayingBeforeHold`, `rateBeforeHold`, `reverseTimer` and the
`holdThreshold` init parameter all go; their behaviour now lives in
`SlowMotionHold`.

- `.seek(direction)` calls `performArrowTap(direction)` directly.
- `.slowMotionBegan(direction)` calls `hold.begin(direction, players: [player])`.
- `.slowMotionEnded` calls `hold.end()`.
- Every path that used to call `endArrow(performTap: false)` to clear stale
  hold state — `applyTransport`, `scrub(to:)`, `selectAthlete`, `changeVideo`,
  `openDirectory`, `connectGoogleDrive`, `setKeyboardControlsEnabled(false)` —
  calls `hold.end()` instead.
- `togglePlayback`'s special case for pausing and resuming a live hold is
  dropped. Space during a hold now plays or pauses ordinarily; the hold is a
  held key, so there is no longer a durable state for Space to steer.

`applyTransport(.slow)` — the tortoise button's one-shot 0.25× — is unchanged.

### `ComparisonModel`

- `.seek` keeps routing through `applyTransport(.back1 / .forward1)`, so ±1 s,
  the ±5 s double-tap, and the left/right/both targeting all behave as they do
  today.
- `.slowMotionBegan(direction)` resolves `target` to players: `.both` →
  `[leftPlayer, rightPlayer]`; `.left` / `.right` → that side's player, except
  while `isSynced`, where it drives the pair — matching `playIndividual`,
  which already refuses to run one clip alone out of a locked pair.
- `.slowMotionEnded` calls `hold.end()`. `close()` and `pauseBoth()` do too.
- A per-side hold while aligning records `noteTouched(side)`, like every other
  side-directed entry point.

### Risk to settle first

AppKit withholds `keyUp` while ⌘ is down. That suppression is documented at
the `NSWindow` level, and this code uses `NSEvent.addLocalMonitorForEvents`,
which runs above it — so key-up should arrive. That is a reasoned expectation,
not a measured fact, and the whole hold-while-held design rests on it.

**First implementation step** is a throwaway harness that logs ⌘+arrow key-up
seen through a local monitor. If key-up does not fire, the fallback is to end
the hold from `flagsChanged` plus a key-repeat watchdog, and that change comes
back for approval before being taken.

### Testing

- `AppKitInputSourceTests`: ⌘+arrow down emits `.slowMotionBegan`; its key-up
  emits `.slowMotionEnded`; releasing ⌘ first still ends the hold exactly once;
  a bare arrow emits `.seek` on down and nothing on up; ⌃/⌥ combinations are
  still refused; a text field still swallows everything.
- New `SlowMotionHoldTests`: forward sets 0.35×; backward with a reversible
  item sets −0.35×; backward without one starts the timer and leaves the
  player paused; `end()` restores the prior rate; `end()` twice is a no-op.
- `ViewerModelIntentTests` / `ViewerTransportTests`: retarget the existing
  `beginArrow`/`endArrow` assertions onto the new intents; keep the double-tap
  coverage as it is.
- `ComparisonModelTests`: `.slowMotionBegan` under each `target`, and under
  `isSynced` with a side targeted, reaches the right players.

## Part 2 — Events

### Grouping rule

The event is the folder **directly above the athlete folder**, not the first
component beneath the chosen root:

| Layout | Event | Athlete |
| --- | --- | --- |
| `root/Event/Athlete/*.mp4` | `Event` | `Athlete` |
| `root/Athlete/*.mp4` | none | `Athlete` |
| `root/Season/Event/Athlete/*.mp4` | `Event` | `Athlete` |

Taking the first component instead would call the third row's event `Season`,
and would mistake the second row's athlete folder for an event. The rule above
needs no special case for mixed depths within one tree.

### Model

`AthleteGroup` gains `event: String?`, and its `id` becomes event-scoped:
`"<eventKey>/<athleteKey>"`, both folded case- and diacritic-insensitively.
Grouping keys on the pair, so:

- Alice at Neuss and Alice at Oberhof are **two** groups, each holding only
  that event's clips.
- `Alice` and `alice` within one event still merge, as today.

This reverses `VideoLibraryTests.testMergesSameAthleteAcrossEventsCaseInsensitively`,
which is rewritten to pin the split. The behaviour change is the point of the
feature, not a regression.

`ViewerModel.athletes` stays the flat, ordered list. It is what `selectAthlete`,
`changeAthlete` and selection-by-id operate on, so PageUp/PageDown keep walking
a single sequence — now in section order. The sidebar renders a derived

```swift
public struct EventGroup: Identifiable {
    public let id: String
    public let name: String?      // nil = the trailing event-less section
    public let athletes: [AthleteGroup]
}
```

computed from that same array, so the list and the sections cannot disagree.

### Ordering

Events sort **descending** by name; with date-prefixed folders
(`2026-08-02_Oberhof`) that puts the most recent event on top. Athletes sort
alphabetically within an event, as they do now. Groups with no event collect
in a trailing unnamed section. If nothing in the tree has an event, that
section is the only one and the sidebar renders exactly as it does today.

### Sidebar

`List(model.filteredAthletes)` becomes `List { ForEach(events) { Section(header:) { ForEach(athletes) } } }`,
with the same per-row name-and-count layout inside.

Search matches the athlete name **or** the event name, so typing `Oberhof`
narrows to that event. Sections left empty by the filter are dropped.

### Downstream surfaces

Where there is no section header to carry the event, it is spelled out:

- `clipDescription` → `Clip 3 of 5 · 2026-08-02_Oberhof · C0007.mp4`
- `comparisonLibrary` → the choice name becomes `Alice — 2026-08-02_Oberhof`,
  so `ClipSourceMenu` can tell the two Alices apart.

Both omit the event entirely when it is `nil`.

### Google Drive

`GoogleDriveClient.scanSharedDrive` builds its own `AthleteGroup`s and today
threads only `parentName` through its recursion. It threads the grandparent
too and applies the same rule. Without this the two sources would disagree
about what an athlete is, and the same Drive folder would group differently
from its local mirror.

### Untouched

`SortingLibrary` and `SortingModel` already write `Event/Athlete` output
folders and deliberately scan only top-level raw video. No change.

### Testing

- `VideoLibraryTests`: the merge test becomes a split test; a new case for
  `root/Athlete/*.mp4` yielding `event == nil`; a new case for
  `root/Season/Event/Athlete` picking `Event`; a mixed-depth tree.
- New coverage for `EventGroup` ordering — descending events, alphabetical
  athletes, event-less section last — and for the search matching event names.
- `ViewerModel`: `clipDescription` with and without an event;
  `comparisonLibrary` names distinguishing two same-named athletes.
- Drive scan coverage mirroring the local grouping rule.
