import Foundation

/// The picker payloads `ViewerModel.comparisonLibrary` hands to the comparison
/// window. They live here rather than beside `ComparisonModel` because
/// `ViewerModel` builds them and the dependency only points one way: the app
/// target sees `SkiVideoCore`, never the reverse. `ComparisonModel` itself
/// follows in task 7.
///
/// The stored properties are `public` because the comparison UI reads them;
/// the memberwise initializers stay internal because only `ViewerModel` builds
/// these, and it lives in this module.
/// How a comparison pane turns the choice an operator picked into a file it
/// can open.
///
/// **A named type rather than a bare closure, because the shape is repeated
/// far more often than it is used.** It is produced in exactly one place
/// (`ContentView`, capturing `ViewerModel.prepareClip`) and called in exactly
/// one place (`ComparisonModel.load(_:side:prepare:)`); every step in between
/// — the presenter protocol, both platforms' presenters, the window
/// controller, `ComparisonView`, `ComparisonPane`, `ClipSourceMenu` — only
/// forwards it unopened. Written out anonymously, that forwarding restated the
/// type at seventeen sites across twelve files, and each of them had to be
/// visited to add anything to it. Measured when exactly that happened: a
/// refusal needs to carry *why*, and a bare `URL?` had nowhere to put the
/// reason, so it went through a side channel on the other window's model and
/// the pane showed a placeholder pointing at it.
///
/// A closure, still, and not a `ViewerModel` reference — that part of the
/// original design was right. `ComparisonModel` has an overload taking a
/// `ViewerModel` directly, but wiring *that* into the UI would mean every step
/// down to `ClipSourceMenu`, in `Shared/` and compiled for both platforms,
/// would have to learn what a `ViewerModel` is purely to hand one along.
/// Naming the type keeps the closure and only stops it being anonymous.
///
/// Follows the convention `AlignmentSessionModel.ComputeFunction` and
/// `SubjectSessionModel.AnalyseFunction` already set here: when a closure
/// crosses more than one boundary, it gets a name and the name carries the
/// rationale.
public struct ClipPreparer {
    /// Three outcomes, not an optional, because "no URL" meant two unrelated
    /// things and the difference mattered to the operator: a local clip needs
    /// no fetch at all, while a refused cloud clip is one the app decided not
    /// to download and owes an explanation for.
    public enum Outcome {
        case ready(URL)
        /// Deliberately not fetched. Carries the operator-facing reason — see
        /// `ClipWeight`, which produces it.
        case refused(String)
        /// Nothing to prepare: a local clip, or no fetcher wired at all.
        /// The caller falls back to the choice's own `playbackURL`.
        case nothingToDo
    }

    private let body: (ComparisonVideoChoice) async -> Outcome

    public init(_ body: @escaping (ComparisonVideoChoice) async -> Outcome) {
        self.body = body
    }

    /// For a preview, a local library, or any surface with no fetcher behind
    /// it. Exists so those call sites name the absence instead of each
    /// spelling out an empty closure — the three that did were part of what
    /// made the type expensive to change.
    public static var none: ClipPreparer { ClipPreparer { _ in .nothingToDo } }

    public func callAsFunction(_ choice: ComparisonVideoChoice) async -> Outcome {
        await body(choice)
    }
}

public struct ComparisonVideoChoice: Identifiable {
    public let id: String
    public let name: String
    public let playbackURL: URL
    /// What this clip's analysis is filed under.
    ///
    /// Carried rather than derived from `playbackURL`, because for a cloud
    /// clip that URL is a path under `Caches` — a sidecar written there is
    /// reclaimed by cache eviction and may be purged by iOS outright. The
    /// identity is the one thing about a clip that does not move.
    public let identity: ClipIdentity
}

public struct ComparisonAthleteChoice: Identifiable {
    public let id: String
    public let name: String
    public let videos: [ComparisonVideoChoice]
}
