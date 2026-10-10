import AppKit
import SwiftUI

/// Reports the `NSWindow` a SwiftUI view ends up in.
///
/// SwiftUI's `WindowGroup` builds the viewer's window itself and hands the
/// app no reference to it, but the viewer's `AppKitInputSource` needs one to
/// scope its keys to that window (`AppKitInputSource.ownWindow`). A zero-size
/// AppKit view placed in the viewer's hierarchy learns its window from
/// `viewDidMoveToWindow`, which AppKit calls whenever the view joins or
/// leaves one — so a window rebuilt later is reported again.
///
/// Chosen over looking the window up through `NSApp.windows`: that list also
/// holds the sorting and comparison windows, panels and sheets, and picking
/// "the viewer's" out of it would mean matching on a title or a class — a
/// guess. This is the view's own window by construction.
struct HostWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
