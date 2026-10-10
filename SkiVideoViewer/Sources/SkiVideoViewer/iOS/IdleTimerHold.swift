import UIKit

extension ScreenAwakeHold {
    /// `UIApplication.isIdleTimerDisabled`, the switch for Auto-Lock. See
    /// `ScreenAwakeHold` for why an upload holds it.
    static let idleTimer = ScreenAwakeHold(
        read: { UIApplication.shared.isIdleTimerDisabled },
        write: { UIApplication.shared.isIdleTimerDisabled = $0 }
    )
}
