import Foundation

/// One clip-position formatter for both screens.
///
/// Lived on `ComparisonModel` while the comparison screen was its only caller.
/// The viewer's control bar reads out the same way, and a viewer that formatted
/// `9.05` as `00:09.1` while the comparison screen wrote `00:09.0` would be a
/// difference nobody chose.
public enum Timecode {
    public static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, remainder)
    }
}
