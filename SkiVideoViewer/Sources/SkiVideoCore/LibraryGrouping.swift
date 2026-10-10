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
    /// end. Both comparisons are `localizedCaseInsensitiveCompare`, so the
    /// order — and with it the sidebar's sections — is locale-dependent and not
    /// reproducible across machines set to different locales. Deliberate: the
    /// sidebar is read by a person, who wants their own collation.
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

        // Sorting first is what makes "the first spelling seen wins" mean
        // anything: the winner is the one on the path-alphabetically-first
        // clip, not whatever order the caller happened to hand over. A local
        // scan hands over raw `FileManager.enumerator` order, which APFS
        // returns in name-hash order — so without this, sibling folders that
        // fold alike (`Andre/` and `André/`, typed inconsistently across two
        // card imports) would show whichever label the directory hash favoured,
        // and it would change when the library was copied to another volume.
        // The event name is picked the same way and is the sidebar's *sort*
        // key, so a flipped spelling can move a whole section.
        for entry in entries.sorted(by: pathOrder) {
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
                    id: id(event: key.event, athlete: key.athlete),
                    name: athleteNames[key] ?? key.athlete,
                    event: key.event.flatMap { eventNames[$0] },
                    videos: (videos[key] ?? []).sorted {
                        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                    }
                )
            }
    }

    /// The sidebar tags its rows by this and looks groups up by it, so two
    /// groups sharing one would leave the second permanently unselectable.
    ///
    /// U+0000 separates because it is the one character that can appear in
    /// neither a POSIX path component nor a Google Drive folder name, and the
    /// leading tag keeps "no event" apart from "an event named the empty
    /// string". Joining on `/` was both: `("a/b", "c")` and `("a", "b/c")` made
    /// one id, as did a nil event and an empty one. Drive names may contain `/`
    /// and may be empty, which is exactly the scanner Task 8 routes through
    /// here.
    private static func id(event: String?, athlete: String) -> String {
        guard let event else { return "a\u{0}\(athlete)" }
        return "e\u{0}\(event)\u{0}\(athlete)"
    }

    /// Re-orders an already built group list for whichever dimension leads the
    /// sidebar — `group(_:)` always folds and *builds* in event-led order;
    /// this only re-sorts its output, so it never re-derives an id and a
    /// pivot never disturbs a selection riding on one.
    ///
    /// Both directions reuse the two comparisons `group(_:)` already made —
    /// events descending, athletes ascending — just swapping which is
    /// primary: leading by event sorts sections descending with athletes
    /// ascending inside; leading by athlete sorts sections alphabetically
    /// with events descending inside.
    static func order(_ groups: [AthleteGroup], by grouping: SidebarGrouping) -> [AthleteGroup] {
        switch grouping {
        case .event:
            return groups.sorted(by: eventLeads)
        case .athlete:
            return groups.sorted(by: athleteLeads)
        }
    }

    /// `group(_:)`'s own event-then-athlete order, restated over the already
    /// folded `AthleteGroup` values instead of the raw `Key`/name tables —
    /// there are no folded-key ties left to break here, because two groups
    /// that folded alike are one group by the time `group(_:)` returns, so
    /// ties break on `id` purely for a total, deterministic order.
    private static func eventLeads(_ left: AthleteGroup, _ right: AthleteGroup) -> Bool {
        switch (left.event, right.event) {
        case let (lhs?, rhs?) where lhs != rhs:
            let byName = lhs.localizedCaseInsensitiveCompare(rhs)
            if byName == .orderedSame { return left.id < right.id }
            return byName == .orderedDescending
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            let byName = left.name.localizedCaseInsensitiveCompare(right.name)
            if byName == .orderedSame { return left.id < right.id }
            return byName == .orderedAscending
        }
    }

    /// The mirror of `eventLeads`: athlete name leads (ascending), event
    /// breaks the tie (descending) rather than the other way round.
    private static func athleteLeads(_ left: AthleteGroup, _ right: AthleteGroup) -> Bool {
        let byName = left.name.localizedCaseInsensitiveCompare(right.name)
        if byName != .orderedSame {
            return byName == .orderedAscending
        }
        switch (left.event, right.event) {
        case let (lhs?, rhs?) where lhs != rhs:
            let byEvent = lhs.localizedCaseInsensitiveCompare(rhs)
            if byEvent == .orderedSame { return left.id < right.id }
            return byEvent == .orderedDescending
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            return left.id < right.id
        }
    }

    /// A total order on entries, so the pre-sort above is itself deterministic.
    /// `path` alone ties for two Drive clips that share a file name — their URLs
    /// differ only in the host, which carries the file id — so the full URL
    /// breaks it.
    private static func pathOrder(_ left: Entry, _ right: Entry) -> Bool {
        let byPath = left.video.path.localizedCaseInsensitiveCompare(right.video.path)
        if byPath == .orderedSame {
            return left.video.absoluteString < right.video.absoluteString
        }
        return byPath == .orderedAscending
    }

    /// Internal, not private: the event rename must match folder names by
    /// exactly this rule, or it would miss a spelling the sidebar shows as
    /// part of the event it was asked to rename.
    static func fold(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
