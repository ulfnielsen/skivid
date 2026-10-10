import SwiftUI

/// Keeps an iPhone or iPad from auto-locking while an upload batch runs.
///
/// Why. The batch is foreground and watched by design (see `SortingSheet`'s
/// `onDisappear`): it runs on ordinary `URLSession` requests, not a background
/// session. A coach who starts it and then waits for Auto-Lock — thirty
/// seconds to a few minutes — has the app sent to the background, where iOS
/// suspends it and the upload in flight with it; the batch then sits
/// half-done until the phone is unlocked. Holding the idle timer off for the
/// batch's length is the narrow fix. (That suspension is iOS's documented
/// app-lifecycle behaviour; it has not been measured on a device here.)
///
/// Counted, not a flag, because the session tray and the history tray can
/// both exist, and the first batch to end must not let the phone lock under
/// the other. The value found on the first hold is restored on the last
/// release, so a timer something else had already switched off stays off.
///
/// The UIKit flag lives behind two closures so this bookkeeping can be tested
/// from a macOS test; `platform` supplies the real one on iOS and nothing on
/// macOS, which has no Auto-Lock to suspend the app.
@MainActor
final class ScreenAwakeHold {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var holders = 0
    private var saved = false

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func acquire() {
        if holders == 0 {
            saved = read()
            write(true)
        }
        holders += 1
    }

    func release() {
        guard holders > 0 else { return }
        holders -= 1
        if holders == 0 { write(saved) }
    }

    /// The app's one hold on the idle timer, or nil where there is none.
    static var platform: ScreenAwakeHold? {
        #if os(iOS)
        return idleTimer
        #else
        return nil
        #endif
    }
}

/// Holds `ScreenAwakeHold.platform` for as long as `active` is true and the
/// view is on screen.
struct KeepsScreenAwake: ViewModifier {
    let active: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { update(active) }
            .onChange(of: active) { update($0) }
            // A tray dismissed mid-batch cancels that batch (`SortingSheet`),
            // so nothing is left uploading to stay awake for.
            .onDisappear { update(false) }
    }

    private func update(_ wanted: Bool) {
        guard wanted != holding, let hold = ScreenAwakeHold.platform else { return }
        holding = wanted
        if wanted { hold.acquire() } else { hold.release() }
    }
}
