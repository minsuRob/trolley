import AppKit
import TrolleyKit

/// The menu bar icon: a way in that is visible before you know trolley exists.
///
/// Until now the only way to say anything to trolley was to notice the floating
/// folder and click it -- discoverable only to someone already told. The menu bar
/// is where a Mac user looks for a background app, so that is where the way in
/// belongs.
///
/// Lives in `Sources/trolley` rather than `TrolleyWidget` on purpose.
/// `trolley mcp --widget` builds a `StatusWidgetController` too, and that process
/// must not put an icon in the menu bar. Gating by call site -- only
/// `WelcomeFlow.run()` ever constructs this -- is stronger than another flag on an
/// initialiser that already has six parameters. It also needs
/// `SetupWindowController`, which `TrolleyWidget` cannot see.
///
/// Main-thread only, like the widget controllers it sits beside -- by convention
/// rather than by `@MainActor`, so it can be built from `WelcomeFlow.run()`
/// alongside them.
final class MenuBarController: NSObject {
    /// The only strong reference to the item. `NSStatusBar` does not retain it for
    /// you: drop this and the icon disappears at the next pool drain.
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private let onAsk: () -> Void
    private let onOpenWiki: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    /// Whether there is a vault to open. Read once, when the menu is built: a folder
    /// that appears while the app is running is a rare enough thing that rebuilding the
    /// menu on a timer would be paying forty times a minute for it.
    private let wikiIsAvailable: () -> Bool

    init(
        onAsk: @escaping () -> Void,
        onOpenWiki: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        wikiIsAvailable: @escaping () -> Bool = { WikiSettings.rootIsReadable }
    ) {
        self.onAsk = onAsk
        self.onOpenWiki = onOpenWiki
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.wikiIsAvailable = wikiIsAvailable
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "trolley.statusItem"
        // Deliberately not `behavior = .removalAllowed`: a ⌘-dragged-away icon has
        // no way back, and would leave a running process with no visible surface --
        // the same trap that keeps "hide" out of the pet's menu.

        if let button = item.button {
            // Template so it inverts correctly in a dark menu bar. The title is a
            // fallback for a system where the symbol lookup comes back nil, which
            // would otherwise leave an invisible strip you cannot click on purpose.
            let image = NSImage(
                systemSymbolName: "folder.fill", accessibilityDescription: "trolley"
            )
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "T" }
            button.toolTip = "trolley"
        }

        // An accessory app often has no key window, and auto-enabling then greys
        // out items that have a perfectly good explicit target.
        menu.autoenablesItems = false
        for spec in MenuBarMenu.specs(wikiIsAvailable: wikiIsAvailable()) {
            switch spec {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let action):
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                // `NSMenuItem.target` is a *weak* reference. If this controller is
                // released the menu survives -- retained by the status item -- and
                // every item silently stops doing anything.
                entry.target = self
                entry.isEnabled = true
                menu.addItem(entry)
            }
        }
        item.menu = menu
        statusItem = item
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc fileprivate func askTapped() { onAsk() }
    @objc fileprivate func wikiTapped() { onOpenWiki() }
    @objc fileprivate func settingsTapped() { onOpenSettings() }
    @objc fileprivate func quitTapped() { onQuit() }
}

/// The menu's shape, as data -- so its wording and order can be asserted without a
/// window server.
enum MenuBarMenu {
    enum Spec: Equatable {
        case item(String, Selector)
        case separator
    }

    /// In the order someone reaches for them. "물어보기" first because it is the whole
    /// point; "종료" last, behind a separator, because it is the one that cannot be undone.
    ///
    /// "위키" is absent when there is no readable vault, rather than present and greyed.
    /// A disabled item is a promise that something could be done here, and there is
    /// nothing a person can do about a folder from a menu -- the setup window is where
    /// that conversation belongs, and it is one item down.
    static func specs(wikiIsAvailable: Bool) -> [Spec] {
        var specs: [Spec] = [.item("물어보기", #selector(MenuBarController.askTapped))]
        if wikiIsAvailable {
            specs.append(.item("위키", #selector(MenuBarController.wikiTapped)))
        }
        specs.append(.item("설정", #selector(MenuBarController.settingsTapped)))
        specs.append(.separator)
        specs.append(.item("종료", #selector(MenuBarController.quitTapped)))
        return specs
    }

    static func titles(wikiIsAvailable: Bool) -> [String] {
        specs(wikiIsAvailable: wikiIsAvailable).compactMap { spec in
            if case .item(let title, _) = spec { return title }
            return nil
        }
    }
}
