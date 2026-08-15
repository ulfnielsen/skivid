import AVFoundation
import Foundation

/// Answers "can this device actually show this clip?" before the coach is left
/// staring at a black rectangle.
///
/// This exists because of a real library. Every clip resized before
/// `resize_video.py` pinned its output (`982b761`, 2026-08-01) is H.264
/// **High 4:4:4 Predictive, 10-bit**, and VideoToolbox on iPhone and iPad
/// cannot decode that at all. The container still parses and the AAC track
/// still plays, so the symptom is sound with no picture — which is
/// indistinguishable from a bug in the download path, and in this project it
/// cost a diagnosis to tell them apart.
///
/// The app cannot repair it at playback: iOS cannot decode the track, so
/// `AVPlayer` fails, and `AVAssetReader` cannot read it either, which rules
/// out transcoding on the device. Saying so plainly is the whole remedy
/// available here — the fix belongs in the library, via
/// `scripts/reencode_for_ios.py`.
public enum ClipPlayability {
    /// Nil when the clip is fine, or when the question does not apply.
    ///
    /// **`AVAssetTrack.isDecodable` does not answer this, and was tried
    /// first.** On an iOS 26.5 simulator it returns `true` for a
    /// `High 4:4:4 Predictive / yuv444p10le` clip that the device then fails to
    /// render — measured by `ClipPlayabilityOnIOSTests` before this
    /// implementation replaced it. A banner driven by `isDecodable` would
    /// never once have appeared.
    ///
    /// So the profile is read from the stream itself. Byte 1 of the `avcC`
    /// configuration record is `AVCProfileIndication`; iOS decodes Baseline
    /// (66), Main (77) and High (100), and none of the high-bit-depth or
    /// high-chroma profiles above them.
    public static func unsupportedVideoMessage(for url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            // No video track at all, or the asset would not load. Neither is
            // the thing this type is here to report, and claiming an
            // unsupported format for a missing file would misdirect.
            return nil
        }
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let profile = h264Profile(of: description),
              let name = unsupportedProfileNames[profile] else {
            return nil
        }
        return "This clip's video can't be decoded on this device — only its sound will play. "
            + "It was saved as \(name) H.264, which iPads cannot open. "
            + "Re-encoding it in the club library fixes it for good."
    }

    /// The H.264 profiles above High that iOS has no decoder for, named as a
    /// coach-facing phrase rather than by number.
    ///
    /// Deliberately a list of what is *unsupported* rather than a `> 100`
    /// comparison: profile numbers are not ordered by capability, and a future
    /// profile iOS does support would otherwise be flagged as broken.
    private static let unsupportedProfileNames: [UInt8: String] = [
        110: "10-bit",
        122: "4:2:2",
        244: "10-bit 4:4:4",
    ]

    /// `AVCProfileIndication` — byte 1 of the `avcC` record, per ISO/IEC
    /// 14496-15. Nil for anything that is not H.264, which includes HEVC:
    /// iOS decodes HEVC Main10 quite happily, so a bit-depth rule written
    /// across codecs would flag clips that play.
    private static func h264Profile(of description: CMFormatDescription) -> UInt8? {
        guard description.mediaSubType == .h264 else { return nil }
        let atoms = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        guard let record = atoms?["avcC"] as? Data, record.count > 1 else { return nil }
        return record[record.startIndex + 1]
    }
}
