import AVFoundation
import AppKit
import SwiftUI
import XCTest
@testable import SkiVideoCore
@testable import SkiVideoViewer

/// Headless layout measurement for `ViewerPane`'s caption, on the same
/// `NSHostingView`/`fittingSize` harness as `ViewerLayoutMeasurementTests`.
///
/// The caption gained a `.thinMaterial` capsule and two type steps because
/// white-on-white over snow was illegible. Both changes make it *wider*, and it
/// shares the pane's bottom edge with the zoom chip — so the question this file
/// answers is where the two now meet, and whether that is anywhere an operator
/// would actually be.
@MainActor
final class ViewerCaptionLayoutTests: XCTestCase {
    /// **Measured**, and the number the overlap arithmetic starts from:
    /// `ViewerPane.zoomChip(in:)` occupies 264pt of trailing width — a 240pt
    /// capsule (the `ZoomControl`'s 224pt intrinsic width, which the
    /// `.frame(maxWidth: 220)` cannot compress, plus 8pt of inner padding each
    /// side) inside 12pt of outer padding each side. Restated from
    /// `zoomChip(in:)`'s own doc comment, where it was measured.
    private static let zoomChipWidth: CGFloat = 264

    private var temporaryDirectory: URL?

    override func setUp() {
        super.setUp()
        // NSHostingView will not lay anything out without the shared
        // application. `.prohibited` keeps it off screen and out of the Dock.
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    /// The narrowest pane this app is expected to run on: an iPad mini in
    /// portrait, 744pt, with the sidebar collapsed. The same width
    /// `zoomChip(in:)`'s own note treats as the floor.
    private static let narrowestRealisticPane: CGFloat = 744

    /// **Measured on this harness**, athlete name over clip description:
    ///
    /// | caption | before | after |
    /// | ------------------------------------- | ----- | ----- |
    /// | "Ada" / no event, short filename      | 125.0 | 162.0 |
    /// | "Ada Lovelace" / no event             | 189.0 | 231.0 |
    /// | "Ada Lovelace-Byron" / evented        | 335.0 | 390.0 |
    /// | 28-char name / evented, camera filename | 352.0 | 409.0 |
    ///
    /// "before" is the old `.headline`/`.caption` caption with no background;
    /// "after" is the shipping `.title3` semibold / `.subheadline` in a
    /// `.thinMaterial` capsule. The capsule and the two type steps cost 37–57pt
    /// of width.
    ///
    /// **The overlap point moved, and it moved to somewhere nobody is.** The
    /// zoom chip owns the trailing 264pt, so a caption runs under it once the
    /// pane is narrower than `captionWidth + 264` — which the change pushed from
    /// 616pt to 673pt for the worst caption measured. Both are below the 744pt
    /// floor: on an iPad mini in portrait the widest realistic caption still
    /// stops 71pt short of the chip. That is the whole overlap answer, and it is
    /// why this shipped rather than being re-thought.
    ///
    /// The width the caption is *given* is not capped, deliberately — see
    /// `ViewerPane.caption`. Adding a background made a pre-existing overlap
    /// visible rather than creating one; a longer library than any measured here
    /// would collide on a narrow pane, and would do so legibly, over a chip that
    /// still takes every click because the caption declines hits.
    func testTheWidestRealisticCaptionClearsTheZoomChipOnAnIPadMiniPane() throws {
        let cases: [(String, String?, String)] = [
            ("Ada", nil, "run3.mov"),
            ("Ada Lovelace", nil, "2026-01-14 run 3.mov"),
            ("Ada Lovelace-Byron", "Hafjell GS January", "2026-01-14 14-32-05 run 3.mov"),
            ("Wilhelmina Featherstonehaugh", "Kvitfjell Super-G Nationals", "GX010123-run-07-final.MP4"),
        ]
        let roomBeforeTheChip = Self.narrowestRealisticPane - Self.zoomChipWidth
        var widths: [String: CGFloat] = [:]

        for (name, event, file) in cases {
            let model = try makeLoadedModel(athlete: name, event: event, file: file)
            let width = captionWidth(model: model, athleteName: name)
            print("CAPTION name=\"\(name)\" description=\"\(model.clipDescription)\" "
                + "width=\(width) meetsChipAtPaneWidth=\(width + Self.zoomChipWidth)")

            XCTAssertLessThanOrEqual(
                width,
                roomBeforeTheChip,
                """
                the caption for "\(name)" measured \(width)pt, which runs under the zoom chip \
                on a \(Self.narrowestRealisticPane)pt pane — only \(roomBeforeTheChip)pt is \
                free before the chip's trailing \(Self.zoomChipWidth)pt
                """
            )
            widths[name] = width
        }

        // **The lower bound is the styling guard, and it is the only headless
        // hold on it.** A capsule and a font are not readable off a hosted
        // SwiftUI view, but they are the two things that made this caption
        // wider, so the width stands in for them: reverting to the old
        // `.headline`/`.caption` with no background measured 352.0pt against
        // this 409.0pt. Without this assertion the whole file passes with the
        // illegible caption restored, since every other check here is an upper
        // bound.
        XCTAssertEqual(
            try XCTUnwrap(widths["Wilhelmina Featherstonehaugh"]),
            409,
            accuracy: 20,
            """
            the widest caption must still carry the type step and the material \
            capsule; the pre-fix `.headline`/`.caption` caption with no \
            background measured 352.0pt here
            """
        )
    }

    // MARK: - helpers

    private func captionWidth(model: ViewerModel, athleteName: String) -> CGFloat {
        let host = NSHostingView(rootView: ViewerPane(model: model, athleteName: athleteName).caption)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func makeLoadedModel(athlete: String, event: String?, file: String) throws -> ViewerModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryDirectory = root
        // An event becomes a folder level above the athlete, which is what puts
        // it into `clipDescription` — the longest line the caption can carry.
        let parent = event.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let directory = parent.appendingPathComponent(athlete, isDirectory: true)
        _ = try makeRealVideoFile(in: directory, name: file, seconds: 1)

        let model = ViewerModel(
            input: AppKitInputSource(),
            folderPicker: AppKitFolderPicker(),
            oauthPresenter: StubOAuthPresenter()
        )
        model.openDirectory(root)
        return model
    }

    /// Duplicated from `SkiVideoCoreTests/RealVideoFixture.swift` for the same
    /// cross-target reason `ZoomWiringTests` duplicates it: that helper is an
    /// `XCTestCase` extension scoped to a target this one does not depend on.
    private func makeRealVideoFile(in directory: URL, name: String, seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90,
            ]
        )
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, Int32(frame % 251), CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(Int(seconds * Double(fps))), timescale: fps))
        let written = expectation(description: "fixture written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 60)
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}
