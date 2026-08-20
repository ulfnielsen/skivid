import Foundation

/// Whether a clip is too heavy to be worth fetching, judged from metadata alone.
///
/// Coaches upload footage straight to the club's Shared Drive, so those clips
/// never pass through this app's resize step — one observed example is 400MB,
/// and playing it means fetching all of it.
///
/// **The bar is the app's own output.** `AVFoundationMediaPipeline` targets
/// 1.784 bits per pixel per second, which is 3.70 Mbps at 1080p, and that
/// number is measured rather than chosen: on real footage the step halved a
/// clip from 7.41 to 3.70 Mbps. A clip more than twice that is carrying detail
/// this app would not have kept.
///
/// No AVFoundation and no network here on purpose: Drive returns width, height
/// and duration in the sweep it already performs, so the whole judgement is
/// arithmetic on values the app has before it downloads anything.
public enum ClipWeight {
    /// Bits per second per output pixel — `AVFoundationMediaPipeline`'s own
    /// constant, restated here because that type is about encoding and this one
    /// is about deciding. If the pipeline's target ever moves, this must move
    /// with it or the app will refuse clips it would itself produce.
    static let targetBitsPerPixel = 1.784

    /// Room for ordinary encoder variation. At 1× a clip merely encoded a
    /// little more richly than this app's own output would be refused, which is
    /// not what the feature is for.
    static let allowedMultiple = 2.0

    /// The pipeline never emits above this, so anything larger is detail the
    /// player will throw away — see `AVFoundationMediaPipeline`'s
    /// `min(1920/w, 1080/h, 1)`.
    static let maximumWidth = 1920
    static let maximumHeight = 1080

    public struct Verdict: Equatable {
        public let isTooLarge: Bool
        /// Nil when the clip is fine. Carries the numbers when it is not: the
        /// operator is being refused a download and "too big" alone gives them
        /// nothing to act on or to disagree with.
        public let explanation: String?

        static let fine = Verdict(isTooLarge: false, explanation: nil)
    }

    /// `nil` for any of the three metadata values means Drive has not told us —
    /// it fills `videoMediaMetadata` in asynchronously after an upload — and a
    /// non-positive value means it told us something useless. Both are the same
    /// answer: do not refuse what cannot be measured. Refusing then would
    /// strike hardest exactly when a coach has just uploaded footage and wants
    /// to watch it.
    public static func verdict(
        width: Int?, height: Int?, durationMillis: Int?, size: Int64
    ) -> Verdict {
        guard let width, let height, let durationMillis,
              width > 0, height > 0, durationMillis > 0, size > 0
        else {
            return .fine
        }

        if width > maximumWidth || height > maximumHeight {
            return Verdict(
                isTooLarge: true,
                explanation: """
                \(formatted(size)), \(width)×\(height) — larger than this app \
                plays (\(maximumWidth)×\(maximumHeight)), so the extra detail \
                is downloaded and then discarded.
                """
            )
        }

        let seconds = Double(durationMillis) / 1000
        let measured = Double(size) * 8 / seconds
        let target = Double(width * height) * targetBitsPerPixel
        guard measured > target * allowedMultiple else { return .fine }

        return Verdict(
            isTooLarge: true,
            explanation: """
            \(formatted(size)) — about \(String(format: "%.0f", measured / target))× \
            the bitrate this app produces for \(width)×\(height). Resizing it \
            would not change the framerate.
            """
        )
    }

    /// Megabytes in the operator's terms — Drive reports these in decimal, and
    /// a clip the Finder calls 400MB should not be described as 381.
    private static func formatted(_ size: Int64) -> String {
        "\(Int((Double(size) / 1_000_000).rounded())) MB"
    }
}
