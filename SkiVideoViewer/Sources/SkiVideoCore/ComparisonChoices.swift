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
}

public struct ComparisonAthleteChoice: Identifiable {
    public let id: String
    public let name: String
    public let videos: [ComparisonVideoChoice]
}
