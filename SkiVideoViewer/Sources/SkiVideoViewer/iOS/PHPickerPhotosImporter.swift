import PhotosUI
import SkiVideoCore
import UIKit
import UniformTypeIdentifiers

/// Lets the coach pick videos from Photos and copies them into a scratch
/// folder the sort can read like any other source.
///
/// `PHPickerViewController` runs out of process: the app never sees the
/// library, only the copies the coach chose. That is why there is no
/// `PHPhotoLibrary` authorisation here, no usage description in the Info.plist
/// and nothing that deletes or edits a Photos asset — Photos stays read-only.
///
/// The copying is `PhotosClipExporter`, which is unit-tested; this file is
/// only the picker and an `NSItemProvider` adapter, and is not covered by any
/// test target — `Package.swift` excludes `Sources/SkiVideoViewer/iOS`.
@MainActor
final class PHPickerPhotosImporter: NSObject, PhotosImporting {
    private let exporter: PhotosClipExporter
    private var continuation: CheckedContinuation<[PHPickerResult], Never>?

    init(exporter: PhotosClipExporter = PhotosClipExporter()) {
        self.exporter = exporter
    }

    func importClips() async throws -> URL? {
        let results = await pick()
        guard !results.isEmpty else { return nil }
        return try await exporter.export(results.map { PickedProviderMovie(provider: $0.itemProvider) })
    }

    func discard() {
        exporter.clear()
    }

    private func pick() async -> [PHPickerResult] {
        var configuration = PHPickerConfiguration()
        configuration.filter = .videos
        // 0 is "no limit": a coach's run is as many clips as they filmed.
        configuration.selectionLimit = 0
        // `.current` hands over the file as stored rather than transcoding it
        // for compatibility, which would be slow and would change the clip.
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self

        return await withCheckedContinuation { continuation in
            guard let presenter = UIKitFolderPicker.topViewController(),
                  presenter.viewIfLoaded?.window != nil
            else {
                continuation.resume(returning: [])
                return
            }
            self.continuation = continuation
            presenter.present(picker, animated: true)
        }
    }
}

extension PHPickerPhotosImporter: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        // Niling first makes a second callback a no-op rather than a double
        // resume, which traps.
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: results)
    }
}

/// `NSItemProvider` is not `Sendable`, but this one is only ever asked to load
/// a file, which it does from any thread.
private struct PickedProviderMovie: PickedMovie, @unchecked Sendable {
    let provider: NSItemProvider

    var suggestedName: String? { provider.suggestedName }

    func withFile(_ body: @escaping @Sendable (URL) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The URL is deleted when this handler returns, so `body` has to
            // finish inside it.
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try body(url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
