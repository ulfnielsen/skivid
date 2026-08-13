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
