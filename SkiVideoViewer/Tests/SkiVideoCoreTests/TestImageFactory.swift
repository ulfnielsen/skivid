import CoreGraphics
import CoreImage
import Foundation

/// Builds synthetic images for registration tests. Generated in code rather than
/// committed as binary fixtures, and deterministic for a given seed so failures
/// reproduce exactly.
enum TestImageFactory {
    /// A dark field scattered with randomly coloured, randomly sized squares.
    /// The clutter is deliberate: image registration needs corner-like features,
    /// and a smooth gradient would give it nothing to match.
    static func textured(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 10_000) / 10_000.0
        }

        for _ in 0..<400 {
            context.setFillColor(
                CGColor(red: next(), green: next(), blue: next(), alpha: 1)
            )
            let size = 6 + next() * 26
            context.fill(
                CGRect(
                    x: next() * Double(width),
                    y: next() * Double(height),
                    width: size,
                    height: size
                )
            )
        }
        return context.makeImage()!
    }

    /// Applies a known transform and crops back to the original frame, so the
    /// result is the same size as the input and the transform is ground truth.
    static func transformed(_ image: CGImage, by transform: CGAffineTransform) -> CGImage {
        let ciImage = CIImage(cgImage: image).transformed(by: transform)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return CIContext().createCGImage(ciImage, from: rect)!
    }

    /// A uniformly semi-transparent version of a textured image. Every pixel's
    /// alpha is set to the requested value, with RGB premultiplied accordingly.
    /// Used to test alpha-channel thresholding: a 75% opaque image (alpha=191)
    /// must be classified correctly by the metric, and is only classified correctly
    /// by direct alpha render (191 > 127 threshold) but not by the old RGB→Gray
    /// approach (which extracts 191 as gray ~113 < 127 threshold).
    static func semiTransparent(_ image: CGImage, alpha: UInt8) -> CGImage {
        let width = image.width
        let height = image.height

        // Extract source image into premultiplied RGBA buffer
        var srcBuffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let srcContext = CGContext(
            data: &srcBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        srcContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Modify each pixel's alpha and premultiply RGB by the new alpha factor.
        // For premultiplied format: RGB_out = RGB_in * (alpha_new / 255)
        let newAlphaFactor = Double(alpha) / 255.0
        for i in 0..<(width * height) {
            let offset = i * 4
            // Unpremultiply current RGB (divide by current alpha if non-zero)
            let currentAlpha = Double(srcBuffer[offset + 3])
            let alphaMult = currentAlpha > 0 ? 255.0 / currentAlpha : 0
            let r = Double(srcBuffer[offset + 0]) * alphaMult
            let g = Double(srcBuffer[offset + 1]) * alphaMult
            let b = Double(srcBuffer[offset + 2]) * alphaMult

            // Premultiply by new alpha
            srcBuffer[offset + 0] = UInt8(clamping: Int(r * newAlphaFactor))
            srcBuffer[offset + 1] = UInt8(clamping: Int(g * newAlphaFactor))
            srcBuffer[offset + 2] = UInt8(clamping: Int(b * newAlphaFactor))
            srcBuffer[offset + 3] = alpha
        }

        guard let resultContext = CGContext(
            data: &srcBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        return resultContext.makeImage() ?? image
    }
}
