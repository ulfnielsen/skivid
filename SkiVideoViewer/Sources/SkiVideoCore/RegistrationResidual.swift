import CoreGraphics
import CoreImage
import Foundation
import simd

public struct Residual {
    /// Mean absolute per-pixel luminance difference in 0...255 units,
    /// measured over the region where both images have pixels.
    public let meanAbsoluteDifference: Double
    /// Fraction of the reference frame where both images have pixels, 0...1.
    /// A tiny overlap makes a small mean difference meaningless, so this must
    /// always be read alongside it.
    public let overlapFraction: Double

    public init(meanAbsoluteDifference: Double, overlapFraction: Double) {
        self.meanAbsoluteDifference = meanAbsoluteDifference
        self.overlapFraction = overlapFraction
    }
}

public enum RegistrationResidual {
    public static let identityWarp = matrix_float3x3(1)

    /// Warps `floating` by `warp` and measures how well it then matches
    /// `reference`. This is the difference blend, quantified: the number
    /// predicts what the overlay's Difference mode would look like.
    public static func measure(
        reference: CGImage,
        floating: CGImage,
        warp: matrix_float3x3
    ) -> Residual {
        let width = reference.width
        let height = reference.height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)

        let transform = CGAffineTransform(
            a: CGFloat(warp.columns.0.x), b: CGFloat(warp.columns.0.y),
            c: CGFloat(warp.columns.1.x), d: CGFloat(warp.columns.1.y),
            tx: CGFloat(warp.columns.2.x), ty: CGFloat(warp.columns.2.y)
        )

        // Render the warped floating image over a transparent bed, so pixels
        // that fall outside the frame stay at alpha 0 and can be excluded
        // from the comparison rather than counted as black.
        let warped = CIImage(cgImage: floating)
            .transformed(by: transform)
            .cropped(to: frame)

        guard
            let referenceGray = grayscaleBytes(from: CIImage(cgImage: reference), in: frame),
            let warpedGray = grayscaleBytes(from: warped, in: frame),
            let warpedAlpha = alphaBytes(from: warped, in: frame)
        else {
            return Residual(meanAbsoluteDifference: 255, overlapFraction: 0)
        }

        var total = 0.0
        var counted = 0
        for index in 0..<(width * height) where warpedAlpha[index] > 127 {
            total += abs(Double(referenceGray[index]) - Double(warpedGray[index]))
            counted += 1
        }

        guard counted > 0 else {
            return Residual(meanAbsoluteDifference: 255, overlapFraction: 0)
        }
        return Residual(
            meanAbsoluteDifference: total / Double(counted),
            overlapFraction: Double(counted) / Double(width * height)
        )
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private static func grayscaleBytes(from image: CIImage, in frame: CGRect) -> [UInt8]? {
        // Render to a grayscale CGImage, then extract bytes from it.
        guard let cgImage = context.createCGImage(image, from: frame) else { return nil }
        return bytesFromGrayscaleCGImage(cgImage)
    }

    private static func alphaBytes(from image: CIImage, in frame: CGRect) -> [UInt8]? {
        // Render the alpha channel directly to avoid RGB→Gray luma weighting.
        // CIImage's alpha is opaque=255, transparent=0. A direct render preserves
        // this; smuggling alpha through red channel + grayscale loses 49% due to
        // luma coefficients, pushing fully opaque pixels to ~130 (just 3 above the
        // 127 threshold) and partially-opaque pixels below it, misclassifying them
        // as excluded. See: CoreGraphics RGB→Gray applies 0.299R + 0.587G + 0.114B,
        // so pure red (alpha in red channel) = 0.299*255 ≈ 76 in grayscale; we were
        // relying on the bias vector to add 54 to reach 130. Direct alpha render
        // gives 0...255 unmangled.
        guard let cgImage = context.createCGImage(image, from: frame) else { return nil }
        return alphaFromCGImage(cgImage)
    }

    private static func bytesFromGrayscaleCGImage(_ cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        // Draw the image into the grayscale context.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func alphaFromCGImage(_ cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height)

        // Use grayscale color space for alpha-only context. Alpha is extracted as
        // 0 (transparent) to 255 (opaque) with no RGB→Gray lossy conversion.
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else {
            return nil
        }

        // Draw the image into the alpha-only context. This preserves the full
        // 0...255 range and correctly handles partial alpha from anti-aliasing
        // and sub-pixel transforms.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
