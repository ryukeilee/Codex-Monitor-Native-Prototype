import AppKit

/// Menu bar only entry point.
///
/// The app owns its status item and popover through AppKit, so it deliberately
/// declares no SwiftUI scene. A SwiftUI `App` needs a scene, and a
/// `Settings { EmptyView() }` placeholder makes SwiftUI present an empty
/// "CodexMonitorNative Settings" window when the app launches or when the
/// Settings… menu item is chosen, which is the blank window a fresh launch used
/// to show. Running the same delegate through `NSApplication` keeps the
/// lifecycle identical without ever creating a window the app has no content
/// for.
@main
@MainActor
enum CodexMonitorNativeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        // `NSApplication.delegate` is weak; keep the delegate alive for the
        // whole run loop instead of relying on the local variable lifetime.
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
