import Foundation

/// What the media pipeline can fail with.
///
/// The ffmpeg pipeline this replaces surfaced whatever the binary wrote to
/// stderr. AVFoundation's own errors are often opaque ("Cannot Open"), so the
/// cases that a user can act on are named here and the file is always included
/// — a sort run touches many clips and "Cannot Open" alone does not say which.
public enum MediaPipelineError: LocalizedError, Equatable {
    /// The asset exists but AVFoundation cannot read it. Matroska, WebM and
    /// most AVI land here.
    case unreadableSource(String)
    case noVideoTrack(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadableSource(name):
            return "\(name) is not in a format this app can read. Convert it to MP4 or MOV first."
        case let .noVideoTrack(name):
            return "\(name) has no video track."
        case let .exportFailed(message):
            return message
        }
    }
}
