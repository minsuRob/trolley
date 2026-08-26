import CoreGraphics
import Foundation
import TrolleyKit

public struct AppSummary {
    public let name: String
    public let bundleID: String
    public let pid: pid_t
    public let isActive: Bool

    public init(name: String, bundleID: String, pid: pid_t, isActive: Bool) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.isActive = isActive
    }
}

/// The trolley tool surface. Every OS boundary arrives as an injected
/// dependency, matching TrolleyKit's existing seam style, so the dispatch and
/// argument handling are testable against fakes.
public final class TrolleyTools: ToolProviding {
    private let trustChecker: TrustChecking
    private let locator: RunningAppLocating
    private let launcher: AppLauncher
    /// Built per call, because delivering keystrokes to a specific pid is what
    /// gets them past an active input method.
    private let makeKeyPoster: (pid_t?) -> KeyEventPosting
    /// One seam serves every mouse action: the coordinate tools drive the
    /// animator directly, and the AXPress-fallback closure is derived from it,
    /// so the fallback click glides exactly like an explicit click_at.
    private let mousePoster: MouseEventPosting?
    private let screenCapturer: ScreenCapturing?
    private let makeRoot: (pid_t, AXChildrenRetryPolicy) -> AXElementProviding
    private let listRunningApps: () -> [AppSummary]
    /// Synthesized keystrokes go to the frontmost app, not to whatever AX
    /// element holds focus, so anything that types must be able to front the
    /// owning app by pid.
    private let activateApp: (pid_t) -> Bool
    private let clipboard: ClipboardAccessing
    private let inputSource: InputSourceControlling
    /// Present only when a wiki folder is configured. Nil keeps `wiki_search` and
    /// `wiki_read` off the tool list entirely, because a listed tool that cannot
    /// work costs the model a call to find that out.
    private let wiki: WikiTools?
    private let executablePath: () -> String
    private let sleeper: (TimeInterval) -> Void
    private let now: () -> Date

    private let registry = ElementRegistry()

    /// Animated cursor movement built over `mousePoster`; nil when no poster
    /// was injected (headless test configurations).
    private var animator: MouseAnimator? {
        mousePoster.map { MouseAnimator(poster: $0, sleeper: sleeper) }
    }

    /// The AXPress-fallback click, in the `(CGPoint) -> Void` shape
    /// `ActionExecutor` expects -- animated, so a fallback click glides the
    /// same way an explicit click_at does.
    private var mouseClicker: ((CGPoint) -> Void)? {
        animator.map { animator in { animator.animatedClick(to: $0) } }
    }
    /// AXManualAccessibility is a one-shot, asynchronous signal; re-sending it
    /// (and re-paying the settle delay) on every call would make each snapshot
    /// needlessly slow.
    private var manualAccessibilitySignalled = Set<pid_t>()

    public init(
        trustChecker: TrustChecking,
        locator: RunningAppLocating,
        launcher: AppLauncher = AppLauncher(),
        makeKeyPoster: @escaping (pid_t?) -> KeyEventPosting,
        mousePoster: MouseEventPosting? = nil,
        screenCapturer: ScreenCapturing? = nil,
        makeRoot: @escaping (pid_t, AXChildrenRetryPolicy) -> AXElementProviding,
        activateApp: @escaping (pid_t) -> Bool,
        listRunningApps: @escaping () -> [AppSummary],
        clipboard: ClipboardAccessing = NSPasteboardClipboard(),
        inputSource: InputSourceControlling = TISInputSourceController(),
        wiki: WikiTools? = nil,
        executablePath: @escaping () -> String = { AccessibilityPermission.currentExecutablePath() },
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.trustChecker = trustChecker
        self.locator = locator
        self.launcher = launcher
        self.makeKeyPoster = makeKeyPoster
        self.mousePoster = mousePoster
        self.screenCapturer = screenCapturer
        self.makeRoot = makeRoot
        self.listRunningApps = listRunningApps
        self.activateApp = activateApp
        self.clipboard = clipboard
        self.inputSource = inputSource
        self.wiki = wiki
        self.executablePath = executablePath
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: - Tool definitions

    public var tools: [ToolDefinition] {
        var definitions: [ToolDefinition] = [
            ToolDefinition(
                name: "check_permissions",
                description: "Check whether trolley has macOS Accessibility trust. Every other tool needs it. "
                    + "Trust is granted to the trolley binary itself, at its exact path.",
                inputSchema: Schema.object([:])
            ),
            ToolDefinition(
                name: "list_apps",
                description: "List running apps with a normal UI, including their bundle ids and pids.",
                inputSchema: Schema.object([
                    "nameContains": Schema.string("Case-insensitive filter over app name and bundle id.")
                ])
            ),
            ToolDefinition(
                name: "launch_app",
                description: "Launch an app if it isn't running, then bring it to the front.",
                inputSchema: Schema.object([
                    "bundleId": Schema.string("Bundle identifier, e.g. com.apple.TextEdit."),
                    "timeoutSeconds": Schema.number("How long to wait for launch.", default: 15)
                ], required: ["bundleId"])
            ),
            ToolDefinition(
                name: "snapshot",
                description: "Read an app's accessibility tree as JSON. Every node gets an id usable with "
                    + "click/focus/type_text/set_ax_value. Start here to see what the app exposes. "
                    + "Note that Chromium/Electron web content frequently exposes nothing below the app chrome.",
                inputSchema: Schema.object([
                    "bundleId": Schema.string("Bundle identifier of a running app."),
                    "maxDepth": Schema.integer("Maximum tree depth to walk.", default: 20),
                    "maxNodes": Schema.integer("Maximum nodes to emit; the result reports whether it truncated.", default: 800),
                    "interestingOnly": Schema.boolean(
                        "Collapse text-less wrapper nodes (AXGroup and friends) and splice their children upward.",
                        default: true
                    ),
                    "textContains": Schema.string("Emit only nodes whose value/title/description contains this."),
                    "role": Schema.string("Emit only nodes with this AX role, e.g. AXButton."),
                    "thorough": Schema.boolean(
                        "Retry truncated children arrays and force-populate lazy trees. Much slower; "
                        + "needed for Chromium/Electron apps, wasted on native ones.",
                        default: false
                    )
                ], required: ["bundleId"])
            ),
            ToolDefinition(
                name: "find_elements",
                description: "Find elements by a case-insensitive substring of their value/title/description "
                    + "and/or by AX role, most specific first. Give role alone to address something with no "
                    + "text of its own, such as an empty text area. Returns ids usable with the action tools.",
                inputSchema: Schema.object([
                    "bundleId": Schema.string("Bundle identifier of a running app."),
                    "text": Schema.string("Substring to search for. Optional if role is given."),
                    "role": Schema.string("Restrict to this AX role, e.g. AXTextArea. Optional if text is given."),
                    "maxDepth": Schema.integer("Maximum tree depth to search.", default: 25),
                    "limit": Schema.integer("Maximum matches to return.", default: 10),
                    "thorough": Schema.boolean("Slow, Chromium-tolerant traversal.", default: false)
                ], required: ["bundleId"])
            ),
            ToolDefinition(
                name: "click",
                description: "Click an element via AXPress, falling back to a synthesized mouse click at its "
                    + "centre. Target it by elementId, or by bundleId plus text.",
                inputSchema: Schema.object([
                    "elementId": Schema.string("Id from snapshot or find_elements."),
                    "bundleId": Schema.string("Bundle identifier, when targeting by text."),
                    "text": Schema.string("Substring to match, when targeting by text."),
                    "role": Schema.string("Restrict the text match to this AX role.")
                ])
            ),
            ToolDefinition(
                name: "focus",
                description: "Give an element keyboard focus, falling back to a click. Reads AXFocused back "
                    + "afterwards so a silent no-op is visible.",
                inputSchema: Schema.object([
                    "elementId": Schema.string("Id from snapshot or find_elements."),
                    "bundleId": Schema.string("Bundle identifier, when targeting by text."),
                    "text": Schema.string("Substring to match, when targeting by text."),
                    "role": Schema.string("Restrict the text match to this AX role.")
                ])
            ),
            ToolDefinition(
                name: "type_text",
                description: "Insert text (Korean, emoji, anything) into a focused field. Always pass "
                    + "elementId or bundleId: input goes to the frontmost app, so without one the text "
                    + "lands in whatever app is in front. Reports which method ran and whether the text "
                    + "was verified to have arrived -- treat verification=\"unverifiable\" as unknown, "
                    + "not as success.",
                inputSchema: Schema.object([
                    "text": Schema.string("Text to insert."),
                    "elementId": Schema.string(
                        "Front this element's app, focus it, insert, then read it back. Required to verify."
                    ),
                    "bundleId": Schema.string("Activate this app first, then insert into whatever holds focus."),
                    "method": Schema.enumString(
                        "paste (default): clipboard plus cmd+V, then the clipboard is put back -- carries "
                        + "any Unicode and works in Chromium/Electron. keys: real per-keystroke events; "
                        + "ASCII only, and it briefly switches the input source to ABC -- use for "
                        + "search-as-you-type or autocomplete fields that ignore a paste. unicode: legacy "
                        + "CGEvent Unicode injection, measured NOT to be delivered on this machine; kept "
                        + "only for diagnosing other setups.",
                        values: TextEntryMethod.allCases.map(\.rawValue),
                        default: TextEntryMethod.paste.rawValue
                    ),
                    "verifyTimeoutSeconds": Schema.number(
                        "How long to poll the element for the text to appear. Raise it for a slow app; "
                        + "a value that is too low reports a successful insert as a failure.",
                        default: 2.0
                    ),
                    "pasteSettleSeconds": Schema.number(
                        "Fixed wait before restoring the clipboard, used only when the element reports no "
                        + "value so the paste cannot be observed.",
                        default: 0.3
                    )
                ], required: ["text"])
            ),
            ToolDefinition(
                name: "press_key",
                description: "Press a named key with optional modifiers, e.g. key=n modifiers=[cmd] for New. "
                    + "Key names are physical US-layout positions, which is how macOS matches shortcuts. "
                    + "To enter characters as text, use type_text instead.",
                inputSchema: Schema.object([
                    "key": Schema.string("Key name: a letter or digit, or return, tab, escape, left, end, f1…"),
                    "modifiers": Schema.stringArray("Modifier names: cmd, shift, option, control."),
                    "bundleId": Schema.string("Activate this app first.")
                ], required: ["key"])
            ),
            ToolDefinition(
                name: "set_ax_value",
                description: "Write an element's AXValue directly and read it back. Faster than typing, but "
                    + "silently ignored by some editors -- always check the returned readback.",
                inputSchema: Schema.object([
                    "elementId": Schema.string("Id from snapshot or find_elements."),
                    "value": Schema.string("New value. Pass an empty string to clear the field.")
                ], required: ["elementId", "value"])
            ),
            ToolDefinition(
                name: "wait_for_element",
                description: "Poll until an element matching the text appears, or time out. Use this instead "
                    + "of guessing a sleep duration after an action that loads new UI.",
                inputSchema: Schema.object([
                    "bundleId": Schema.string("Bundle identifier of a running app."),
                    "text": Schema.string("Substring to wait for. Optional if role is given."),
                    "role": Schema.string("Restrict to this AX role. Optional if text is given."),
                    "timeoutSeconds": Schema.number("Give up after this long.", default: 10),
                    "pollIntervalSeconds": Schema.number("Delay between attempts.", default: 0.5),
                    "maxDepth": Schema.integer("Maximum tree depth to search.", default: 25),
                    "thorough": Schema.boolean("Slow, Chromium-tolerant traversal.", default: false)
                ], required: ["bundleId"])
            ),
            ToolDefinition(
                name: "screenshot",
                description: "Capture the main display (or a region of it) as a JPEG image. Use this when "
                    + "snapshot/find_elements return nothing useful -- typical for Chromium/Electron web "
                    + "content -- then click what you see with click_at. Coordinates: the accompanying JSON "
                    + "reports capturedRegion (global screen points) and pointsPerPixel. To click a feature "
                    + "you see at image pixel (px, py): screenX = capturedRegion.x + px * pointsPerPixel; "
                    + "screenY = capturedRegion.y + py * pointsPerPixel; then call click_at with that. By "
                    + "default pointsPerPixel is 1.0, so image pixels map 1:1 to screen points. Requires "
                    + "Screen Recording permission (separate from Accessibility).",
                inputSchema: Schema.object([
                    "x": Schema.number("Region origin x in global screen points. Give all four region values or none."),
                    "y": Schema.number("Region origin y in global screen points."),
                    "width": Schema.number("Region width in points."),
                    "height": Schema.number("Region height in points."),
                    "maxWidth": Schema.integer(
                        "Cap the output image width in pixels; the image scales down to fit and "
                        + "pointsPerPixel rises accordingly.",
                        default: 1440
                    )
                ])
            ),
            ToolDefinition(
                name: "click_at",
                description: "Move the mouse smoothly to a global screen point and left-click. For "
                    + "coordinates derived from a screenshot, apply the formula from the screenshot tool "
                    + "description first. Prefer the click tool when an AX element id is available -- it is "
                    + "faster and survives window moves.",
                inputSchema: Schema.object([
                    "x": Schema.number("Global screen x in points (top-left origin)."),
                    "y": Schema.number("Global screen y in points.")
                ], required: ["x", "y"])
            ),
            ToolDefinition(
                name: "move_mouse",
                description: "Move the mouse smoothly to a global screen point without clicking -- useful "
                    + "for hover states or positioning before a manual step.",
                inputSchema: Schema.object([
                    "x": Schema.number("Global screen x in points (top-left origin)."),
                    "y": Schema.number("Global screen y in points.")
                ], required: ["x", "y"])
            )
        ]
        if wiki != nil {
            definitions.append(contentsOf: WikiTools.definitions)
        }
        return definitions
    }

    // MARK: - Dispatch

    public func call(name: String, arguments: JSONValue) throws -> JSONValue {
        try dispatch(name: name, arguments: arguments)
    }

    /// Reachable only if a caller uses a name that was never advertised, which is
    /// the one case where the conditional registration above is not enough.
    private func requireWiki() throws -> WikiTools {
        guard let wiki else {
            throw ToolError.wikiUnavailable("No wiki folder is configured.")
        }
        return wiki
    }

    private func dispatch(name: String, arguments: JSONValue) throws -> JSONValue {
        let args = Arguments(arguments)
        switch name {
        case "check_permissions": return checkPermissions()
        case "list_apps": return listApps(args)
        case "launch_app": return try launchApp(args)
        case "snapshot": return try snapshot(args)
        case "find_elements": return try findElements(args)
        case "click": return try click(args)
        case "focus": return try focus(args)
        case "type_text": return try typeText(args)
        case "press_key": return try pressKey(args)
        case "set_ax_value": return try setAXValue(args)
        case "wait_for_element": return try waitForElement(args)
        case "screenshot": return try screenshot(args)
        case "click_at": return try clickAt(args)
        case "move_mouse": return try moveMouse(args)
        case "wiki_search": return try requireWiki().search(args)
        case "wiki_read": return try requireWiki().read(args)
        default:
            throw ToolError(.invalidArgument, "Unknown tool \"\(name)\".")
        }
    }

    // MARK: - Tools

    private func checkPermissions() -> JSONValue {
        let trusted = trustChecker.isProcessTrusted()
        let screenRecording = screenCapturer?.hasScreenRecordingAccess()
        var result: [String: JSONValue] = [
            "trusted": .bool(trusted),
            "executablePath": .string(executablePath())
        ]
        if let screenRecording {
            result["screenRecording"] = .bool(screenRecording)
        }
        var instructions: [String] = []
        if !trusted {
            instructions.append(
                "Open System Settings > Privacy & Security > Accessibility and add the binary at the path "
                + "above. Trust is per executable path, so a rebuilt or moved binary needs re-approving."
            )
        }
        if screenRecording == false {
            instructions.append(
                "The screenshot tool additionally needs Screen Recording (System Settings > Privacy & "
                + "Security > Screen Recording) for the same binary, and trolley must be restarted after "
                + "the grant. AX-only tools work without it."
            )
        }
        if !instructions.isEmpty {
            result["instructions"] = .string(instructions.joined(separator: " "))
        }
        return .object(result)
    }

    private func screenshot(_ args: Arguments) throws -> JSONValue {
        guard let screenCapturer else {
            throw ToolError(.actionFailed, "screen capture is unavailable in this configuration")
        }
        guard screenCapturer.hasScreenRecordingAccess() else {
            // Registers the binary with TCC so it appears in System Settings.
            screenCapturer.requestScreenRecordingAccess()
            throw ToolError.screenRecordingDenied(executablePath: executablePath())
        }

        let region = try regionArgument(args)
        let capture: ScreenCapture
        let rendered: RenderedScreenshot
        do {
            capture = try screenCapturer.captureMainDisplay()
            rendered = try ScreenshotRenderer.render(
                capture,
                region: region,
                maxWidth: max(64, args.int("maxWidth", default: 1440))
            )
        } catch let error as ScreenshotRenderError {
            if case .emptyRegion = error {
                throw ToolError(.invalidArgument, "\(error)")
            }
            throw ToolError(.actionFailed, "\(error)")
        } catch let error as ScreenCaptureError {
            if case .accessDenied = error {
                throw ToolError.screenRecordingDenied(executablePath: executablePath())
            }
            throw ToolError(.actionFailed, "\(error)")
        }

        func rect(_ r: CGRect) -> JSONValue {
            .object([
                "x": .double(Double(r.minX)), "y": .double(Double(r.minY)),
                "width": .double(Double(r.width)), "height": .double(Double(r.height))
            ])
        }
        return .object([
            "pixelWidth": .int(rendered.pixelWidth),
            "pixelHeight": .int(rendered.pixelHeight),
            "pointsPerPixel": .double((rendered.pointsPerPixel * 1000).rounded() / 1000),
            "capturedRegion": rect(rendered.capturedRegion),
            "displayBounds": rect(capture.displayBounds),
            "format": .string("jpeg")
        ])
    }

    /// All four region values or none; a partial region is a coordinate bug on
    /// the caller's side, not something to guess about.
    private func regionArgument(_ args: Arguments) throws -> CGRect? {
        let values = ["x", "y", "width", "height"].map { args.raw[$0]?.doubleValue }
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        guard present.count == 4 else {
            throw ToolError(
                .invalidArgument,
                "Give all four of x, y, width, height (in screen points), or none for the full display."
            )
        }
        return CGRect(x: present[0], y: present[1], width: present[2], height: present[3])
    }

    private func clickAt(_ args: Arguments) throws -> JSONValue {
        var payload = try animatedMove(args)
        payload["clicked"] = .bool(true)
        return .object(payload)
    }

    private func moveMouse(_ args: Arguments) throws -> JSONValue {
        .object(try animatedMove(args, clicking: false))
    }

    private func animatedMove(_ args: Arguments, clicking: Bool = true) throws -> [String: JSONValue] {
        try requireTrust()
        guard let animator else {
            throw ToolError(.actionFailed, "mouse control is unavailable in this configuration")
        }
        guard let x = args.raw["x"]?.doubleValue, let y = args.raw["y"]?.doubleValue else {
            throw ToolError(.invalidArgument, "Both x and y are required, in global screen points.")
        }

        let target = CGPoint(x: x, y: y)
        let report = clicking ? animator.animatedClick(to: target) : animator.animatedMove(to: target)
        func point(_ p: CGPoint) -> JSONValue {
            .object(["x": .double(Double(p.x)), "y": .double(Double(p.y))])
        }
        return [
            "movedFrom": point(report.from),
            "movedTo": point(report.to),
            "durationMs": .int(Int(report.duration * 1000))
        ]
    }

    private func listApps(_ args: Arguments) -> JSONValue {
        let filter = args.optionalString("nameContains")
        let apps = listRunningApps().filter { app in
            guard let filter else { return true }
            return app.name.localizedCaseInsensitiveContains(filter)
                || app.bundleID.localizedCaseInsensitiveContains(filter)
        }
        return .object([
            "apps": .array(apps.map { app in
                .object([
                    "name": .string(app.name),
                    "bundleId": .string(app.bundleID),
                    "pid": .int(Int(app.pid)),
                    "active": .bool(app.isActive)
                ])
            })
        ])
    }

    private func launchApp(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let bundleID = try args.string("bundleId")
        let timeout = args.double("timeoutSeconds", default: 15)
        let wasRunning = locator.runningApplication(bundleID: bundleID) != nil

        do {
            let pid = try launcher.launchOrActivate(bundleID: bundleID, locator: locator, timeout: timeout)
            return .object([
                "pid": .int(Int(pid)),
                "wasRunning": .bool(wasRunning)
            ])
        } catch AppLauncherError.applicationNotFound(let bundleID) {
            throw ToolError(
                .appNotFound,
                "No application installed for bundle id \(bundleID).",
                hint: "Use list_apps to see running apps and their exact bundle ids."
            )
        } catch AppLauncherError.launchTimedOut(let bundleID) {
            throw ToolError(.timeout, "Timed out waiting for \(bundleID) to finish launching.")
        } catch {
            throw ToolError(.actionFailed, "\(error)")
        }
    }

    private func snapshot(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let bundleID = try args.string("bundleId")
        let thorough = args.bool("thorough", default: false)
        let (root, pid) = try appRoot(bundleID: bundleID, thorough: thorough)
        if thorough {
            forceManualAccessibility(root: root, pid: pid)
        }

        let options = TreeSnapshotter.Options(
            maxDepth: args.int("maxDepth", default: 20),
            maxNodes: args.int("maxNodes", default: 800),
            interestingOnly: args.bool("interestingOnly", default: true),
            textContains: args.optionalString("textContains"),
            role: args.optionalString("role")
        )
        let result = TreeSnapshotter(registry: registry, options: options).snapshot(root: root)

        var payload: [String: JSONValue] = [
            "bundleId": .string(bundleID),
            "pid": .int(Int(pid)),
            "nodeCount": .int(result.nodeCount),
            "truncated": .bool(result.truncated),
            "tree": .array(result.tree)
        ]
        if result.truncated {
            payload["truncationHint"] = .string(
                "Hit the maxNodes budget; this is not the whole tree. Narrow with textContains or role, "
                + "or lower maxDepth, rather than assuming a missing element is absent."
            )
        }
        if result.nodeCount <= 1 {
            payload["emptyTreeHint"] = .string(
                thorough
                    ? "The app exposed essentially nothing even with thorough=true -- its content is not "
                        + "reachable via accessibility. Switch to the screenshot tool and click what you "
                        + "see with click_at."
                    : "The app exposed essentially nothing. If it is Chromium- or Electron-based, retry "
                        + "with thorough=true; if that also comes back empty, use the screenshot tool and "
                        + "click_at instead."
            )
        }
        return .object(payload)
    }

    private func findElements(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let bundleID = try args.string("bundleId")
        let (text, role) = try textAndRole(args)
        let thorough = args.bool("thorough", default: false)
        let limit = max(1, args.int("limit", default: 10))
        let (root, pid) = try appRoot(bundleID: bundleID, thorough: thorough)
        if thorough {
            forceManualAccessibility(root: root, pid: pid)
        }

        let ranked = rankedMatches(
            root: root,
            text: text,
            role: role,
            maxDepth: args.int("maxDepth", default: 25)
        )
        guard !ranked.isEmpty else {
            throw ToolError.elementNotFound(text: text ?? role ?? "", bundleID: bundleID)
        }

        let matches = ranked.prefix(limit).map { match -> JSONValue in
            var node = describeMatch(match.element)
            node["id"] = .string(registry.register(match.element, pid: pid))
            node["depth"] = .int(match.depth)
            return .object(node)
        }
        return .object([
            "matches": .array(matches),
            "totalMatches": .int(ranked.count)
        ])
    }

    private func click(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let target = try resolveTarget(args)

        var usedMouseFallback = false
        let recordingClicker: ((CGPoint) -> Void)? = mouseClicker.map { real in
            { point in
                usedMouseFallback = true
                real(point)
            }
        }
        let executor = ActionExecutor(
            root: target.element,
            keyPoster: makeKeyPoster(nil),
            mouseClicker: recordingClicker
        )

        switch executor.perform(.click(target.element)) {
        case .ok:
            return .object([
                "clicked": .bool(true),
                "method": .string(usedMouseFallback ? "mouseFallback" : "AXPress"),
                "role": .string(target.element.stringAttribute(AXAttr.role) ?? "?")
            ])
        case .failed(let reason):
            throw ToolError(
                .actionFailed,
                reason,
                hint: "AXPress did nothing and the element reported no on-screen frame to click. "
                    + "Try focusing a nearby element and using press_key instead."
            )
        case .elementFound:
            throw ToolError(.actionFailed, "unexpected result from click")
        }
    }

    private func focus(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let target = try resolveTarget(args)
        let executor = ActionExecutor(
            root: target.element,
            keyPoster: makeKeyPoster(nil),
            mouseClicker: mouseClicker
        )

        let result = executor.perform(.focus(target.element))
        if case .failed(let reason) = result {
            throw ToolError(.actionFailed, reason)
        }
        // AXFocused frequently accepts the write and changes nothing, so report
        // what the element says afterwards rather than just "ok".
        let readback = target.element.boolAttribute(AXAttr.focused)
        return .object([
            "focused": .bool(readback ?? false),
            "focusedReadback": readback.map { JSONValue.bool($0) } ?? .null,
            "role": .string(target.element.stringAttribute(AXAttr.role) ?? "?")
        ])
    }

    private func typeText(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let text = try args.string("text")
        var payload: [String: JSONValue] = ["typed": .int(text.count)]
        var element: AXElementProviding?
        var targetPid: pid_t?

        // Front the owning app *before* focusing: synthesized keystrokes are
        // delivered to the frontmost app regardless of which element holds AX
        // focus, so skipping this doesn't merely no-op -- it types the text into
        // whatever app happened to be in front.
        if let elementID = args.optionalString("elementId") {
            let target = try registry.resolve(elementID)
            guard let pid = registry.pid(for: elementID) ?? target.pid else {
                throw ToolError(
                    .actionFailed,
                    "Element \(elementID) has no owning process, so its app cannot be brought to the front.",
                    hint: "Pass bundleId as well so the right app receives the keystrokes."
                )
            }
            guard activateApp(pid) else {
                throw ToolError(.actionFailed, "could not bring the app owning \(elementID) (pid \(pid)) to the front")
            }
            sleeper(0.4)

            let executor = ActionExecutor(root: target, keyPoster: makeKeyPoster(nil), mouseClicker: mouseClicker)
            if case .failed(let reason) = executor.perform(.focus(target)) {
                throw ToolError(.actionFailed, "could not focus \(elementID): \(reason)")
            }
            payload["focusedElementId"] = .string(elementID)
            element = target
            targetPid = pid
        } else if let bundleID = args.optionalString("bundleId") {
            let (_, pid) = try appRoot(bundleID: bundleID, thorough: false)
            guard locator.activate(bundleID: bundleID) else {
                throw ToolError(.actionFailed, "could not bring \(bundleID) to the front")
            }
            sleeper(0.4)
            targetPid = pid
        } else {
            payload["warning"] = .string(
                "No elementId or bundleId given, so the text went to whatever app was already frontmost. "
                + "Pass one of them to target a specific app."
            )
        }

        let method = try parseMethod(args)
        let engine = TextEntryEngine(
            makePoster: makeKeyPoster,
            clipboard: clipboard,
            inputSource: inputSource,
            sleeper: sleeper
        )

        let outcome: TextEntryOutcome
        do {
            outcome = try engine.insert(
                text,
                method: method,
                element: element,
                targetPid: targetPid,
                pasteSettle: args.double("pasteSettleSeconds", default: 0.3),
                verifyTimeout: args.double("verifyTimeoutSeconds", default: 2.0)
            )
        } catch let error as TextEntryError {
            throw Self.toolError(for: error)
        }

        payload.merge(Self.render(outcome, text: text)) { existing, _ in existing }
        return .object(payload)
    }

    private func parseMethod(_ args: Arguments) throws -> TextEntryMethod {
        guard let raw = args.optionalString("method") else { return .paste }
        guard let method = TextEntryMethod(rawValue: raw) else {
            throw ToolError(
                .invalidArgument,
                "Unknown method \"\(raw)\".",
                hint: "Valid methods: \(TextEntryMethod.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return method
    }

    private static func toolError(for error: TextEntryError) -> ToolError {
        switch error {
        case .unsupportedCharacters(let characters, _):
            return .unsupportedText(characters)
        case .clipboardUnavailable:
            return .clipboardFailed("Could not put the text on the clipboard.")
        case .inputSourceUnavailable:
            return .inputSourceFailed("No ASCII-capable keyboard layout is available to switch to.")
        case .keyPostFailed(let reason):
            return ToolError(.actionFailed, reason)
        }
    }

    /// `verification` is the load-bearing field: "typed" only says what was
    /// sent. Each verdict gets the note that tells the model what to do next.
    private static func render(_ outcome: TextEntryOutcome, text: String) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "method": .string(outcome.method.rawValue),
            "verification": .string(outcome.verification.rawValue),
            "containsTypedText": .bool(outcome.verification == .confirmed)
        ]
        if let before = outcome.valueBefore { payload["valueBefore"] = .string(before) }
        if let after = outcome.valueAfter { payload["valueAfter"] = .string(after) }
        if let restored = outcome.clipboardRestored { payload["clipboardRestored"] = .bool(restored) }
        if let note = outcome.clipboardNote { payload["clipboardNote"] = .string(note) }
        if let restored = outcome.inputSourceRestored { payload["inputSourceRestored"] = .bool(restored) }

        switch outcome.verification {
        case .confirmed:
            break
        case .provablyFailed:
            payload["note"] = .string(
                outcome.secureInputEnabled
                    ? "The element's value is unchanged, so the text definitely did not land. Secure input "
                        + "is enabled system-wide (something like a password field holds focus), which blocks "
                        + "every form of synthesized keyboard input until it is dismissed."
                    : "The element's value is unchanged, so the text definitely did not land. Try "
                        + "method=\"keys\" if the field only responds to real keystrokes, or set_ax_value "
                        + "to write the value directly."
            )
        case .unverifiable:
            payload["note"] = .string(
                "Whether the text arrived could not be checked: no element was targeted, or it does not "
                + "report an AXValue (rich-text and Chromium-backed editors typically don't). Treat this "
                + "as unknown rather than success -- check visually, or pass an elementId that reports a "
                + "value. It was NOT retried with another method, because a retry would risk entering the "
                + "text twice."
            )
        case .changedUnexpectedly:
            payload["note"] = .string(
                "The element's value changed but does not contain \"\(text)\" -- an input method may still "
                + "be composing, or the field reformatted what it received. Read the element back to see "
                + "what it actually holds."
            )
        }
        return payload
    }

    private func pressKey(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let key = try args.string("key")
        let modifiers = args.stringArray("modifiers")

        guard KeyCodeMap.keyCode(forName: key) != nil else {
            throw unknownKey("Unknown key name \"\(key)\".")
        }
        for modifier in modifiers where KeyCodeMap.modifierFlags[modifier.lowercased()] == nil {
            throw unknownKey("Unknown modifier \"\(modifier)\".")
        }

        if let bundleID = args.optionalString("bundleId") {
            _ = try appRoot(bundleID: bundleID, thorough: false)
            guard locator.activate(bundleID: bundleID) else {
                throw ToolError(.actionFailed, "could not bring \(bundleID) to the front")
            }
            sleeper(0.4)
        }

        // Deliberately posted through the system tap rather than to a pid:
        // shortcuts are matched against physical key positions there, which is
        // what makes cmd+n work whatever input source is active.
        guard KeyboardActions.press(key, modifiers: modifiers, using: makeKeyPoster(nil)) else {
            throw unknownKey("Unknown key or modifier in \((modifiers + [key]).joined(separator: "+")).")
        }
        return .object([
            "pressed": .string((modifiers + [key]).joined(separator: "+"))
        ])
    }

    private func setAXValue(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let elementID = try args.string("elementId")
        let value = try args.literalString("value")
        let element = try registry.resolve(elementID)

        let accepted = element.setAttribute(AXAttr.value, value: value as AnyObject)
        let readback = element.stringAttribute(AXAttr.value)
        var payload: [String: JSONValue] = [
            "accepted": .bool(accepted),
            "matchesRequestedValue": .bool(readback == value),
            "readback": readback.map { JSONValue.string($0) } ?? .null
        ]
        if accepted && readback != value {
            payload["warning"] = .string(
                "The write reported success but the value did not change. Rich-text editors "
                + "(Notion, Chromium content) do this; use focus plus type_text instead."
            )
        }
        return .object(payload)
    }

    private func waitForElement(_ args: Arguments) throws -> JSONValue {
        try requireTrust()
        let bundleID = try args.string("bundleId")
        let (text, role) = try textAndRole(args)
        let maxDepth = args.int("maxDepth", default: 25)
        let thorough = args.bool("thorough", default: false)
        let timeout = args.double("timeoutSeconds", default: 10)
        let interval = max(0.05, args.double("pollIntervalSeconds", default: 0.5))

        let (root, pid) = try appRoot(bundleID: bundleID, thorough: thorough)
        if thorough {
            forceManualAccessibility(root: root, pid: pid)
        }

        let started = now()
        let deadline = started.addingTimeInterval(timeout)
        var attempts = 0
        while true {
            attempts += 1
            let ranked = rankedMatches(root: root, text: text, role: role, maxDepth: maxDepth)
            if let match = ranked.first {
                var node = describeMatch(match.element)
                node["id"] = .string(registry.register(match.element, pid: pid))
                node["depth"] = .int(match.depth)
                node["waitedSeconds"] = .double((now().timeIntervalSince(started) * 100).rounded() / 100)
                node["attempts"] = .int(attempts)
                return .object(node)
            }
            guard now() < deadline else { break }
            sleeper(interval)
        }

        throw ToolError(
            .timeout,
            "No element matching \(describeQuery(text: text, role: role)) appeared in \(bundleID) "
                + "within \(timeout)s (\(attempts) attempts).",
            hint: thorough
                ? "Call snapshot with thorough=true to see what the app is actually exposing."
                : "Retry with thorough=true if the app is Chromium- or Electron-based."
        )
    }

    // MARK: - Helpers

    private func requireTrust() throws {
        guard trustChecker.isProcessTrusted() else {
            throw ToolError.notTrusted(executablePath: executablePath())
        }
    }

    private func unknownKey(_ message: String) -> ToolError {
        let keys = KeyCodeMap.byName.keys.sorted().joined(separator: ", ")
        let modifiers = KeyCodeMap.modifierFlags.keys.sorted().joined(separator: ", ")
        return ToolError(
            .unknownKey,
            message,
            hint: "Valid keys: \(keys). Valid modifiers: \(modifiers). "
                + "For ordinary characters use type_text instead."
        )
    }

    /// A role alone is a complete query -- an empty text area has no text to
    /// search for -- so either half suffices, but not neither.
    private func textAndRole(_ args: Arguments) throws -> (text: String?, role: String?) {
        let text = args.optionalString("text")
        let role = args.optionalString("role")
        guard text != nil || role != nil else {
            throw ToolError(
                .invalidArgument,
                "Provide text, role, or both.",
                hint: "Use role on its own to address an element with no text of its own, e.g. role=AXTextArea."
            )
        }
        return (text, role)
    }

    private func describeQuery(text: String?, role: String?) -> String {
        switch (text, role) {
        case let (text?, role?): return "\"\(text)\" with role \(role)"
        case let (text?, nil): return "\"\(text)\""
        case let (nil, role?): return "role \(role)"
        case (nil, nil): return "anything"
        }
    }

    private func appRoot(bundleID: String, thorough: Bool) throws -> (element: AXElementProviding, pid: pid_t) {
        guard let info = locator.runningApplication(bundleID: bundleID) else {
            throw ToolError.appNotRunning(bundleID)
        }
        let policy: AXChildrenRetryPolicy = thorough ? .thorough : .fast
        return (makeRoot(info.processIdentifier, policy), info.processIdentifier)
    }

    /// Chromium/Electron keep their tree lazy until this non-standard attribute
    /// is set, and it lands asynchronously -- hence the settle delay.
    private func forceManualAccessibility(root: AXElementProviding, pid: pid_t) {
        guard !manualAccessibilitySignalled.contains(pid) else { return }
        manualAccessibilitySignalled.insert(pid)
        _ = root.setAttribute(AXAttr.manualAccessibility, value: true as CFBoolean)
        sleeper(1.5)
    }

    private func rankedMatches(
        root: AXElementProviding,
        text: String?,
        role: String?,
        maxDepth: Int
    ) -> [AXMatch] {
        let query = ElementQuery(textContains: text ?? "", roleFilter: role)
        let matches = AXTreeWalker().findAll(
            root: root,
            query: query,
            limits: AXTraversalLimits(maxDepth: maxDepth)
        )
        // rankByLeafiness works on elements; re-associate to keep depth for the caller.
        let order = ElementMatcher.rankByLeafiness(matches.map(\.element))
            .enumerated()
            .reduce(into: [ObjectIdentifier: Int]()) { table, pair in
                table[pair.element.identity()] = pair.offset
            }
        return matches.sorted { lhs, rhs in
            (order[lhs.element.identity()] ?? .max) < (order[rhs.element.identity()] ?? .max)
        }
    }

    private struct Target {
        let element: AXElementProviding
    }

    private func resolveTarget(_ args: Arguments) throws -> Target {
        if let elementID = args.optionalString("elementId") {
            return Target(element: try registry.resolve(elementID))
        }
        guard let bundleID = args.optionalString("bundleId") else {
            throw ToolError(
                .invalidArgument,
                "Provide either elementId, or bundleId plus text and/or role.",
                hint: "Element ids come from snapshot or find_elements."
            )
        }
        let (text, role) = try textAndRole(args)
        let (root, _) = try appRoot(bundleID: bundleID, thorough: false)
        let ranked = rankedMatches(
            root: root,
            text: text,
            role: role,
            maxDepth: args.int("maxDepth", default: 25)
        )
        guard let match = ranked.first else {
            throw ToolError.elementNotFound(text: text ?? role ?? "", bundleID: bundleID)
        }
        return Target(element: match.element)
    }

    private func describeMatch(_ element: AXElementProviding) -> [String: JSONValue] {
        var node: [String: JSONValue] = [
            "role": .string(element.stringAttribute(AXAttr.role) ?? "?")
        ]
        for (attribute, key) in [
            (AXAttr.title, "title"),
            (AXAttr.value, "value"),
            (AXAttr.description, "description")
        ] {
            guard let text = element.stringAttribute(attribute),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            node[key] = .string(text.count > 120 ? String(text.prefix(120)) + "…" : text)
        }
        if let position = element.pointAttribute(AXAttr.position),
           let size = element.sizeAttribute(AXAttr.size) {
            node["frame"] = .array([
                .int(Int(position.x)), .int(Int(position.y)),
                .int(Int(size.width)), .int(Int(size.height))
            ])
        }
        return node
    }
}
