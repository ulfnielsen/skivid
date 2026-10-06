import AVFoundation
import Foundation

/// One video the coach picked from Photos, reduced to what the export needs.
///
/// The seam exists so the export — naming, ordering, scratch hygiene — can be
/// tested and driven without a live `PHPickerViewController`, which runs out of
/// process and cannot be summoned in a unit test. The iOS wrapper adapts
/// `NSItemProvider`; a test (or a UI-test launch-argument seam) supplies files.
public protocol PickedMovie: Sendable {
    /// The original name Photos offers, without its extension — "IMG_0413".
    /// Nil or empty when Photos offers none.
    var suggestedName: String? { get }

    /// Calls `body` with a readable file URL that is only valid for the
    /// duration of the call, exactly as `loadFileRepresentation` does: the
    /// system deletes its temporary copy as soon as the handler returns.
    func withFile(_ body: @escaping @Sendable (URL) throws -> Void) async throws
}

/// Turns picks into a flat folder of clips that `SortingModel` can treat as
/// any other source.
///
/// The folder lives under Caches so a session that is abandoned half-way costs
/// the OS something it may reclaim, not gigabytes the coach cannot see. It is
/// scratch only: the resized, tagged outputs are written elsewhere
/// (`SortingModel.outputRoot`) and outlive it.
public struct PhotosClipExporter: Sendable {
    public let scratchRoot: URL
    private let captureDate: @Sendable (URL) async -> Date?

    /// `captureDate` reads when a copied clip was filmed. The default reads the
    /// movie's own creation-date metadata, because PHPicker hands over no
    /// asset date without `PHPhotoLibrary` authorisation, which this flow
    /// deliberately never asks for.
    public init(
        scratchRoot: URL = PhotosClipExporter.defaultScratchRoot(),
        captureDate: @escaping @Sendable (URL) async -> Date? = PhotosClipExporter.metadataCaptureDate
    ) {
        self.scratchRoot = scratchRoot
        self.captureDate = captureDate
    }

    public static func defaultScratchRoot() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotosPicks", isDirectory: true)
    }

    /// The `creationDate` common metadata item, which Photos videos carry.
    public static func metadataCaptureDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Copies every pick into a fresh scratch folder and returns it.
    ///
    /// Whatever an earlier session left there is discarded first, so picking
    /// again replaces rather than accumulates. If any pick fails the whole
    /// folder is removed and the error rethrown: a source with some of the
    /// coach's clips missing would look complete.
    ///
    /// Names are the original Photos name where there is one. Without one the
    /// clip is named by capture date, so name order — which is what
    /// `SortingLibrary.rawVideos` sorts by — is the order they were filmed in;
    /// failing that, by pick order.
    public func export(_ picks: [PickedMovie]) async throws -> URL {
        clear()
        do {
            try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

            var staged: [(name: String?, date: Date?, url: URL)] = []
            for (index, pick) in picks.enumerated() {
                // Hidden, so a half-finished copy is never mistaken for a clip.
                let holding = scratchRoot.appendingPathComponent(".incoming-\(index)")
                let ext = try await copy(pick, to: holding)
                let url = holding.appendingPathExtension(ext)
                try FileManager.default.moveItem(at: holding, to: url)
                staged.append((
                    Self.cleaned(pick.suggestedName),
                    await captureDate(url),
                    url
                ))
            }

            var taken: Set<String> = []
            for (index, clip) in staged.enumerated() {
                let ext = clip.url.pathExtension
                let base = clip.name ?? Self.fallbackName(date: clip.date, index: index)
                let final = scratchRoot.appendingPathComponent(Self.unique(base, ext: ext, taken: &taken))
                try FileManager.default.moveItem(at: clip.url, to: final)
                // `suggestedEventDate` reads this, so the sort's default event
                // date is the day it was filmed, not the day it was imported.
                if let date = clip.date {
                    try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: final.path)
                }
            }
            return scratchRoot
        } catch {
            clear()
            throw error
        }
    }

    /// Removes the scratch folder and everything in it.
    public func clear() {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    /// Copies one pick and returns the extension of the file it handed over.
    private func copy(_ pick: PickedMovie, to destination: URL) async throws -> String {
        let box = ExtensionBox()
        try await pick.withFile { source in
            try FileManager.default.copyItem(at: source, to: destination)
            let ext = source.pathExtension.lowercased()
            box.value = VideoLibrary.supportedExtensions.contains(ext) ? ext : "mov"
        }
        return box.value ?? "mov"
    }

    private static func cleaned(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func fallbackName(date: Date?, index: Int) -> String {
        guard let date else { return String(format: "Photos clip %02d", index + 1) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Photos \(formatter.string(from: date))"
    }

    /// Case-insensitive, because the folder is sorted that way and a case-only
    /// difference would collide on a case-insensitive volume.
    private static func unique(_ base: String, ext: String, taken: inout Set<String>) -> String {
        var candidate = "\(base).\(ext)"
        var n = 2
        while !taken.insert(candidate.lowercased()).inserted {
            candidate = "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}

private final class ExtensionBox: @unchecked Sendable {
    var value: String?
}
