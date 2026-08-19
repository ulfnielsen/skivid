# SkiVideoViewer

macOS + iPadOS SwiftUI app for reviewing ski training footage.
`SkiVideoCore` is platform-agnostic; `SkiVideoViewer` is the app target.

## Tests

- `swift test` alone fails with "no such module 'XCTest'" — this machine's
  `xcode-select` points at CommandLineTools. Always prefix:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- **Targeted while iterating, full suite only before final sign-off.** ~18 call
  sites open real on-screen windows, which interrupts whoever is at the keyboard.
- The six slowest tests (real Vision/pose analysis over real footage) are
  **skipped by default** — measured, they were 115s of a 207s run. A default
  run is now ~92s. Before sign-off, include them:
  `SKI_SLOW_TESTS=1 DEVELOPER_DIR=... swift test`
- Don't mandate a full run per mutation check. A mutation check only needs the
  tests covering the mutated code; that habit is what made runs feel constant.
- `--filter SkiVideoCoreTests` covers the core module and opens no windows —
  the right loop for anything not touching views.
- `CorrectedStartEndToEndTests` fails ~2 in 9 runs even idle. Not a flake:
  `ComparisonModel.applySync` latches the sync anchor before its own async
  seeks land. Don't chase it as an environment problem.
- `CorePurityTests` fails the build if anything under `Sources/SkiVideoCore`
  names AppKit or UIKit.

## Build and run

- `./run.sh` — rebuild and launch. `./build_app.sh` — ad-hoc signed, local only.
- `./release_app.sh` — Developer ID signed, notarised, stapled → `dist/`.
  Notarisation takes minutes; run it in the background.

## Conventions

- Document *why*, with measured evidence. A confidently wrong mechanism is
  worse than none — several have had to be corrected here.
- Never `git add -A`: `AppBundle/` holds intentionally uncommitted artwork.
- Commit messages: imperative, no `feat:`/`fix:` prefix.
