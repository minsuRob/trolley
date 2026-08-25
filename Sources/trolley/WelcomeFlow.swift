import AppKit
import Foundation
import TrolleyKit

/// What a double-click in Finder does: open the setup window.
///
/// The bundle exists so trolley can be dragged to /Applications, but a CLI
/// launched from Finder has nowhere to print -- without this the icon would just
/// blink and look broken.
enum WelcomeFlow {
    /// Held for the process's lifetime; the window owns the run loop from here.
    private static var controller: SetupWindowController?

    /// launchd sets `__CFBundleIdentifier` to the identifier of the bundle it
    /// opened. Merely being set is not enough to go on: Terminal exports its own
    /// (`com.apple.Terminal`) into every shell it spawns, and a plain `trolley`
    /// typed there would then open a window instead of printing help -- measured,
    /// after this check was first written the loose way. It has to match *our*
    /// identifier, which only a launch of this bundle produces. A bare binary has
    /// no identifier at all, so it never matches.
    static func shouldRun(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard arguments.count == 1, let bundleIdentifier else { return false }
        return environment["__CFBundleIdentifier"] == bundleIdentifier
    }

    static func run() {
        let app = NSApplication.shared
        // .regular so the window can come forward on its own; the MCP server
        // picks .accessory for itself and never reaches this path.
        app.setActivationPolicy(.regular)
        let controller = SetupWindowController()
        Self.controller = controller
        controller.show()
        app.run()
    }
}
