import CoreGraphics
import Foundation
import Vision
import simd

public enum RegistrationMethod: String, CaseIterable {
    case translational
    case homographic
}

public struct RegistrationResult {
    /// The transform to apply to the **floating** image to bring it into
    /// alignment with the reference, as a homogeneous 3x3. Column 2 is the
    /// translation component.
    ///
    /// Vision returns the opposite mapping, so this is the inverse of its
    /// raw output. Applying Vision's value directly moves the floating image
    /// further from alignment — measured on a known (+40, +17) shift, doing
    /// so raised the residual from 59.6 to 61.6, while the inverse brought
    /// it to 0.0.
    public let warp: matrix_float3x3
    public let method: RegistrationMethod
    /// Recorded for the record only. Vision was measured returning 1.0 even
    /// for pairs it registered badly, so this must never gate a decision.
    public let visionConfidence: Float
    /// Wall-clock time of the Vision request alone, excluding image loading.
    public let duration: TimeInterval

    public init(
        warp: matrix_float3x3,
        method: RegistrationMethod,
        visionConfidence: Float,
        duration: TimeInterval
    ) {
        self.warp = warp
        self.method = method
        self.visionConfidence = visionConfidence
        self.duration = duration
    }
}

public enum RegistrationError: Error, Equatable {
    case noObservation
    case degenerateWarp
}

public enum FrameRegistration {
    public static func register(
        reference: CGImage,
        floating: CGImage,
        method: RegistrationMethod
    ) throws -> RegistrationResult {
        let handler = VNImageRequestHandler(cgImage: floating, options: [:])
        let request: VNImageRegistrationRequest
        switch method {
        case .translational:
            request = VNTranslationalImageRegistrationRequest(
                targetedCGImage: reference,
                options: [:]
            )
        case .homographic:
            request = VNHomographicImageRegistrationRequest(
                targetedCGImage: reference,
                options: [:]
            )
        }

        let start = Date()
        try handler.perform([request])
        let duration = Date().timeIntervalSince(start)

        switch method {
        case .translational:
            guard let observation = request.results?.first
                as? VNImageTranslationAlignmentObservation
            else { throw RegistrationError.noObservation }
            return RegistrationResult(
                warp: try invertedWarp(matrix_float3x3(observation.alignmentTransform)),
                method: method,
                visionConfidence: observation.confidence,
                duration: duration
            )
        case .homographic:
            guard let observation = request.results?.first
                as? VNImageHomographicAlignmentObservation
            else { throw RegistrationError.noObservation }
            return RegistrationResult(
                warp: try invertedWarp(observation.warpTransform),
                method: method,
                visionConfidence: observation.confidence,
                duration: duration
            )
        }
    }
}

/// Normalises a homography so `h33 == 1`, then inverts it.
///
/// Homogeneous coordinates are only defined up to scale, and Vision's
/// `warpTransform` does not always come back with `h33 == 1` — one real clip
/// pair produced `h33 = 0.59`, which makes the affine part read ~1.7x off
/// unless it is divided through first.
///
/// Throws `RegistrationError.degenerateWarp` if the matrix is singular or
/// nearly so, or if inversion produces non-finite values. The projective
/// row of the output (third row) may not be normalised to [0,0,1]; the
/// consumer ignores it anyway.
func invertedWarp(_ warp: matrix_float3x3) throws -> matrix_float3x3 {
    var normalised = warp
    let h33 = normalised.columns.2.z
    if h33 != 0 {
        normalised = normalised * (1 / h33)
    }

    // Check determinant is large enough before attempting inversion.
    let det = simd_determinant(normalised)
    guard abs(det) > Float.ulpOfOne.squareRoot() else {
        throw RegistrationError.degenerateWarp
    }

    let inverted = simd_inverse(normalised)

    // Verify the result is finite; inversion of near-singular matrices
    // produces huge-but-finite garbage that the determinant alone would not catch.
    guard inverted.columns.0.x.isFinite,
          inverted.columns.0.y.isFinite,
          inverted.columns.0.z.isFinite,
          inverted.columns.1.x.isFinite,
          inverted.columns.1.y.isFinite,
          inverted.columns.1.z.isFinite,
          inverted.columns.2.x.isFinite,
          inverted.columns.2.y.isFinite,
          inverted.columns.2.z.isFinite else {
        throw RegistrationError.degenerateWarp
    }

    return inverted
}

public extension matrix_float3x3 {
    /// Lifts a 2D affine transform into homogeneous 3x3 form, matching the
    /// column-major layout Vision uses for `warpTransform`, so both
    /// registration methods can be handled with one type downstream.
    init(_ transform: CGAffineTransform) {
        self.init(
            SIMD3<Float>(Float(transform.a), Float(transform.b), 0),
            SIMD3<Float>(Float(transform.c), Float(transform.d), 0),
            SIMD3<Float>(Float(transform.tx), Float(transform.ty), 1)
        )
    }
}
