import CoreGraphics
import Foundation

/// Renders a segment's stored previews back into pictures.
///
/// The sidecar keeps only a time and a normalised box per preview, never an
/// image, so nothing is written next to the operator's footage. The cost is
/// that the pictures have to be redrawn from the clip on demand — five short
/// seeks per segment, which is what this does.
public enum SegmentThumbnails {
    /// Converts a normalised **top-left-origin** box to the pixel rect
    /// `CGImage.cropping(to:)` expects, which is also top-left-origin.
    ///
    /// Not the same as the bottom-left rect `CGContext` drawing needs. Getting
    /// these two confused shipped a bug in this project where every thumbnail
    /// was mirrored vertically about the frame centre while the full-frame
    /// annotations looked correct — and a mirrored crop of snow still looks
    /// like a plausible photograph, so nothing about it seemed wrong until the
    /// boxes were checked against a frame that had a person in the other half.
    static func croppingRect(_ box: CGRect, in image: CGImage) -> CGRect {
        let width = Double(image.width)
        let height = Double(image.height)
        return CGRect(
            x: Double(box.minX) * width,
            y: Double(box.minY) * height,
            width: Double(box.width) * width,
            height: Double(box.height) * height
        )
    }

    /// The padded crop around `box`, clamped to the frame. Returns nil when the
    /// result would be too small to be worth showing.
    public static func crop(
        _ image: CGImage, to box: CGRect, padding: Double = 1.6
    ) -> CGImage? {
        var rect = croppingRect(box, in: image)
        rect = rect
            .insetBy(
                dx: -rect.width * CGFloat(padding - 1) / 2,
                dy: -rect.height * CGFloat(padding - 1) / 2
            )
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return image.cropping(to: rect.integral)
    }

    /// One preview, cropped from the clip at its stored time.
    ///
    /// `sourceWidth` is the width the frame is decoded at, not the width of the
    /// result: a skier occupying a tenth of the frame yields a ~128px crop from
    /// a 1280px decode, which is enough for a thumbnail and cheap enough for
    /// five of them.
    public static func thumbnail(
        clip: URL,
        preview: SegmentPreview,
        padding: Double = 1.6,
        sourceWidth: Double = 1280
    ) throws -> CGImage? {
        // A window rather than an instant: frame times rarely land exactly on
        // a stored preview time, and asking for a zero-length range returns
        // nothing at all.
        let frames = try ClipFrameReader.frames(
            from: clip,
            fps: 1000,
            targetWidth: sourceWidth,
            from: max(0, preview.time - 0.02),
            to: preview.time + 0.06
        )
        guard let frame = frames.first?.image else { return nil }
        return crop(frame, to: preview.box, padding: padding)
    }

    /// A segment's previews composed into one horizontal strip, each cell
    /// `cell` points, letterboxed onto `background` so differing crop shapes
    /// still line up.
    ///
    /// The strip, not a single best frame, is what the operator judges a
    /// segment by: one picture cannot show that a track has changed person
    /// partway through, and spotting exactly that is why they are being asked.
    public static func strip(
        clip: URL,
        segment: AnalysedSegment,
        cell: CGSize = CGSize(width: 72, height: 96),
        scale: Int = 2,
        background: CGColor = CGColor(gray: 0.12, alpha: 1)
    ) throws -> CGImage? {
        guard !segment.previews.isEmpty else { return nil }

        let cellWidth = Int(cell.width) * scale
        let cellHeight = Int(cell.height) * scale
        guard let context = CGContext(
            data: nil,
            width: cellWidth * segment.previews.count,
            height: cellHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))

        for (index, preview) in segment.previews.enumerated() {
            guard let image = try thumbnail(clip: clip, preview: preview) else { continue }
            // Fit, never fill: cropping a thumbnail to fill its cell would
            // trim the skier, which is the one thing the strip exists to show.
            let fit = min(
                Double(cellWidth) / Double(image.width),
                Double(cellHeight) / Double(image.height)
            )
            let drawn = CGSize(
                width: Double(image.width) * fit, height: Double(image.height) * fit
            )
            context.draw(image, in: CGRect(
                x: Double(index * cellWidth) + (Double(cellWidth) - drawn.width) / 2,
                y: (Double(cellHeight) - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
        return context.makeImage()
    }
}
