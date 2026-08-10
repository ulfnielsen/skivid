import Foundation

/// Turns flat `(video, athlete, event)` triples into the sidebar's groups.
///
/// A separate unit rather than a method on `VideoLibrary` because two scanners
/// need it and only one of them walks a filesystem: the Google Drive client
/// recurses folder ids over the network, so a rule that lived in the local
/// scan could only ever be *reimplemented* there. The two disagreed about the
/// supported-extension list until 2026-08-08 for exactly that reason; the
/// grouping rule is not going the same way.
enum LibraryGrouping {
    struct Entry {
        let video: URL
        let athlete: String
        /// The event the athlete's folder sat in, or nil when there was none —
        /// an athlete folder directly under the chosen root.
        let event: String?

        init(video: URL, athlete: String, event: String?) {
            self.video = video
            self.athlete = athlete
            self.event = event
        }
    }

    /// Groups on the folded `(event, athlete)` pair, so `Alice` and `alice` at
    /// one event are one athlete while `Alice` at two events is two — each
    /// holding only that event's clips.
    ///
    /// Events sort descending: the folders are date-prefixed in practice, so
    /// that puts the most recent event at the top of the sidebar. Athletes sort
    /// alphabetically within an event, and groups with no event collect at the
    /// end.
    ///
    /// The comparator is a total order on the keys, not a set of hints on top
    /// of the input's arrangement, because `sorted` is not stable: every pair
    /// of distinct keys lands in exactly one branch, and each branch decides.
    /// Two keys can only tie if they fold alike *and* their display names
    /// compare the same — and then they are the same key, which appears in
    /// `order` once.
    static func group(_ entries: [Entry]) -> [AthleteGroup] {
        struct Key: Hashable {
            let event: String?
            let athlete: String
        }

        var eventNames: [String: String] = [:]
        var athleteNames: [Key: String] = [:]
        var videos: [Key: [URL]] = [:]
        var order: [Key] = []

        for entry in entries {
            let eventKey = entry.event.map(fold)
            let key = Key(event: eventKey, athlete: fold(entry.athlete))
            if let eventKey, let event = entry.event {
                eventNames[eventKey] = eventNames[eventKey] ?? event
            }
            if videos[key] == nil {
                order.append(key)
                athleteNames[key] = entry.athlete
            }
            videos[key, default: []].append(entry.video)
        }

        return order
            .sorted { left, right in
                switch (left.event, right.event) {
                case let (lhs?, rhs?) where lhs != rhs:
                    let lhsName = eventNames[lhs] ?? lhs
                    let rhsName = eventNames[rhs] ?? rhs
                    let byName = lhsName.localizedCaseInsensitiveCompare(rhsName)
                    // Two different events whose display names compare the same
                    // would otherwise tie, and their athletes would interleave
                    // at the whim of the sort. Break on the folded key so the
                    // result stays the same run to run.
                    if byName == .orderedSame { return lhs < rhs }
                    return byName == .orderedDescending
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    let lhsName = athleteNames[left] ?? left.athlete
                    let rhsName = athleteNames[right] ?? right.athlete
                    let byName = lhsName.localizedCaseInsensitiveCompare(rhsName)
                    if byName == .orderedSame { return left.athlete < right.athlete }
                    return byName == .orderedAscending
                }
            }
            .map { key in
                AthleteGroup(
                    id: "\(key.event ?? "")/\(key.athlete)",
                    name: athleteNames[key] ?? key.athlete,
                    event: key.event.flatMap { eventNames[$0] },
                    videos: (videos[key] ?? []).sorted {
                        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                    }
                )
            }
    }

    private static func fold(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
