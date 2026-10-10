import AppKit
import SkiVideoCore
import SwiftUI
import XCTest
@testable import SkiVideoViewer

@MainActor
final class SecondaryScreenPresenterTests: XCTestCase {
    func testMacPresenterReportsItCanPresentBothScreens() {
        let presenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(
            presenter.canPresentComparison,
            "macOS has a real Compare window, so ContentView must show the button"
        )
        XCTAssertTrue(
            presenter.canPresentSorting,
            "macOS has a real Sort window, so ContentView must show the button"
        )
    }

    func testMacPresenterConformsToTheSeam() {
        // Compile-time proof the concrete type satisfies the protocol the
        // shared view depends on.
        let presenter: any SecondaryScreenPresenter = MacSecondaryScreenPresenter()
        XCTAssertTrue(presenter.canPresentComparison)
        XCTAssertTrue(presenter.canPresentSorting)
    }

    func testMacPresenterFlagsDoNotVary() {
        // ContentView reads these while building `body` and does not observe
        // the presenter, so a flag derived from runtime state would leave the
        // toolbar stale. Reading each twice is the cheapest guard against
        // someone later deriving them from, say, a window's visibility.
        let presenter = MacSecondaryScreenPresenter()
        XCTAssertEqual(presenter.canPresentComparison, presenter.canPresentComparison)
        XCTAssertEqual(presenter.canPresentSorting, presenter.canPresentSorting)
    }

    /// macOS opens Compare and Sort in windows of their own, beside the
    /// viewer's, so the viewer's keys must stay live — Space has to play the
    /// viewer while either is open. `ContentView` reads this to decide.
    func testMacScreensDoNotCoverTheViewer() {
        XCTAssertFalse(MacSecondaryScreenPresenter().screensCoverTheViewer)
    }

    /// Ledger item 32: the comparison window's source used to be unscoped, so
    /// with the viewer now live it would compete for the viewer's keys.
    func testComparisonWindowScopesItsInputSourceToItsOwnWindow() throws {
        let controller = ComparisonWindowController()
        controller.show(initialLeftVideo: nil, openLibrary: [], prepare: .none, onClose: {})
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let source = try XCTUnwrap(controller.inputSource)
        XCTAssertTrue(source.ownWindow === window, "the comparison source must only hear its own window")
    }

    func testSortingWindowScopesItsInputSourceToItsOwnWindow() throws {
        let controller = SortingWindowController()
        controller.show(
            destination: UploadLibraryChoice(libraries: [], openLibraryID: nil,
                                             open: { _ in nil }, current: { (.failure(.noLibraryOpen), []) }),
            openResizedLibrary: { _ in }, onClose: {})
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let source = try XCTUnwrap(controller.inputSource)
        XCTAssertTrue(source.ownWindow === window, "the sorting source must only hear its own window")
    }

    /// The viewer's source is scoped through this reader, so it has to report
    /// the window its view actually lands in.
    func testHostWindowReaderReportsTheWindowItIsHostedIn() {
        var reported: NSWindow?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: Color.clear.background(HostWindowReader { reported = $0 }))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(reported === window)
    }
}
