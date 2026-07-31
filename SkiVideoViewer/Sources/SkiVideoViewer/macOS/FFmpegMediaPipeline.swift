import Foundation
import SkiVideoCore

/// The macOS ffmpeg-backed pipeline. Phase 2 replaces this with an
/// AVFoundation implementation that also works on iOS.
struct FFmpegMediaPipeline: MediaPipeline {
    func writeMetadata(athlete: String, to source: URL) async throws {
        let temporary = source.deletingLastPathComponent().appendingPathComponent(
            ".metadata-\(UUID().uuidString).\(source.pathExtension)"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.runFFmpeg([
            "-i", source.path,
            // Camera files can contain telemetry/data tracks that MP4 cannot remux.
            // Preserve the playable streams and the container metadata, but omit
            // those proprietary tracks from the tagged copy.
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-c", "copy",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            temporary.path,
        ])
        _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
    }

    func resize(source: URL, destination: URL, athlete: String) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.runFFmpeg([
            "-i", source.path,
            "-vf", "scale=w=1920:h=1080:force_original_aspect_ratio=decrease",
            "-metadata", "title=\(athlete)",
            "-metadata", "artist=\(athlete)",
            "-metadata", "comment=Athlete: \(athlete)",
            destination.path,
        ])
    }

    private static func runFFmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "SkiVideoViewer.Resize",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "ffmpeg failed"]
            )
        }
    }
}
