import Foundation
import XCTest

/// Opt-in gate for the tests that dominate the suite's wall clock.
///
/// **Measured 2026-08-19**, per-test durations off one full run: six tests take
/// 115s of a ~207s suite — more than half — while the other ~720 average about
/// an eighth of a second each. There is no long tail to trim; it is three
/// classes, all of which run real Vision/pose analysis over real footage:
///
/// |                          | tests | time   |
/// | ------------------------ | ----- | ------ |
/// | `SubjectAnalyzerTests`   | 4     | 82.8s  |
/// | `SegmentThumbnailsTests` | 1     | 16.5s  |
/// | `AlignmentAnalyzerTests` | 1     | 15.4s  |
///
/// They already skip where the ground-truth footage is absent, which is what
/// keeps CI and other machines fast — but on the machine that *has* the
/// footage, every iteration paid for them. This gate is the second half: they
/// skip there too unless asked for.
///
/// **Not a licence to stop running them.** They cover the analysis this app
/// exists to do, against real footage, and a zero-byte fixture cannot stand in
/// — the project has measured that route producing NaN durations and vacuous
/// assertions. Run them before sign-off:
///
///     SKI_SLOW_TESTS=1 DEVELOPER_DIR=… swift test
///
/// The parallel precedent is `ZoomWiringTests`'s on-screen capture test, which
/// self-skips where the environment cannot capture an `AVPlayerLayer`.
extension XCTestCase {
    func requireSlowTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKI_SLOW_TESTS"] == "1",
            "slow analysis test — set SKI_SLOW_TESTS=1 to run it"
        )
    }
}
