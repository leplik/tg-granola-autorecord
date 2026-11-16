import AppKit
import ApplicationServices
import AutorecordCore

/// Finds and presses Granola's "Stop transcript" button through the Accessibility API.
enum GranolaAccessibility {
    /// Seconds any single Accessibility call may wait for Granola.
    private static let messagingTimeout: Float = 2
    /// Upper bound for one pass over Granola's windows, so a hung Granola cannot stall the agent.
    private static let scanTimeLimit: TimeInterval = 8

    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Presses the stop button. `activate` brings an app to the front by its bundle identifier.
    static func pressStopButton(activate: @escaping (String) -> Void, log: @escaping (String) -> Void) -> ButtonPressResult {
        guard isTrusted(prompt: false) else { return .notTrusted }
        guard let session = Session.open(activate: activate) else { return .granolaNotRunning }
        defer { session.close() }
        return StopButtonPress(surface: session, time: SystemTime(), log: log).run()
    }

    /// Human-readable list of every button Granola exposes, for checking the matcher against a new Granola version.
    static func dump() -> String {
        guard isTrusted(prompt: true) else {
            return "No Accessibility permission. Allow it for the app that runs this command, then retry."
        }
        guard let session = Session.open(activate: { _ in }) else { return "Granola is not running." }
        defer { session.close() }
        let scan = session.findStopButton(timeout: 5, collectAll: true)
        var lines = ["\(scan.buttonsSeen) buttons, stop button match: \(scan.match.map { "#\($0)" } ?? "none")"]
        if scan.unresponsive { lines.append("Granola stopped responding during the scan; the list may be incomplete.") }
        if let match = scan.match, !Session.acceptsPress(scan.elements[match]) {
            lines.append("The match has no AXPress yet: Granola's page is in Chromium's basic accessibility mode, usually because its window is behind other windows. `stop` shows Granola before pressing.")
        }
        for (index, candidate) in scan.candidates.enumerated() {
            let button = candidate.button
            let names = [button.title, button.label, button.help].compactMap { $0 }.filter { !$0.isEmpty }
            let marker = index == scan.match ? "=> " : "   "
            let actions = Session.actions(of: scan.elements[index])
            lines.append("\(marker)#\(index) names=\(names) actions=\(actions) classes=\(button.classes.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Session

    struct Scan {
        var elements: [AXUIElement] = []
        var candidates: [StopButtonCandidate] = []
        var match: Int?
        var buttonsSeen = 0
        /// Granola answered an Accessibility call with kAXErrorCannotComplete, which usually means it is hung.
        var unresponsive = false
    }

    private final class Session: StopButtonSurface {
        private let app: AXUIElement
        /// Set when this session turned Electron's accessibility tree on, so that it can turn it off again.
        private let enabledManualAccessibility: Bool
        private let activateApp: (String) -> Void
        /// The button that the latest `scan()` matched.
        private var foundButton: AXUIElement?

        private init(app: AXUIElement, enabledManualAccessibility: Bool, activate: @escaping (String) -> Void) {
            self.app = app
            self.enabledManualAccessibility = enabledManualAccessibility
            self.activateApp = activate
        }

        static func open(activate: @escaping (String) -> Void) -> Session? {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Granola.bundleID).first else {
                return nil
            }
            // Only a timeout set on the system-wide element applies to windows and children too.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)

            var current: CFTypeRef?
            let wasOn = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &current) == .success
                && (current as? Bool) == true
            if !wasOn {
                // Electron builds the web content's accessibility tree only when asked to.
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            return Session(app: app, enabledManualAccessibility: !wasOn, activate: activate)
        }

        /// Leaves Granola as it was: another assistive tool may rely on the tree if it was already on.
        func close() {
            guard enabledManualAccessibility else { return }
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }

        static func actions(of element: AXUIElement) -> [String] {
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
            return (names as? [String]) ?? []
        }

        /// Chromium lists AXPress only in its complete accessibility mode. In the basic mode it drops a press
        /// silently, although AXUIElementPerformAction reports success.
        static func acceptsPress(_ element: AXUIElement) -> Bool {
            actions(of: element).contains(kAXPressAction as String)
        }

        // MARK: StopButtonSurface

        func scan() -> StopButtonScan {
            let result = self.scan(collectAll: false)
            foundButton = result.match.map { result.elements[$0] }
            return StopButtonScan(
                found: foundButton != nil,
                pressable: foundButton.map(Session.acceptsPress) ?? false,
                buttonsSeen: result.buttonsSeen,
                unresponsive: result.unresponsive
            )
        }

        func pressFoundButton() -> Int32 {
            guard let foundButton else { return AXError.invalidUIElement.rawValue }
            return AXUIElementPerformAction(foundButton, kAXPressAction as CFString).rawValue
        }

        /// NSWorkspace stays current without a run loop, so this also works in the CLI. The system-wide
        /// Accessibility element is less reliable: it fails with kAXErrorCannotComplete while Chrome is in front.
        func frontmostAppID() -> String? {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }

        func activate(bundleID: String) {
            activateApp(bundleID)
        }

        /// Chromium fills in the tree asynchronously, so scan repeatedly until a match or the timeout.
        func findStopButton(timeout: TimeInterval, collectAll: Bool = false) -> Scan {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let scan = self.scan(collectAll: collectAll)
                if scan.match != nil || scan.unresponsive || Date() >= deadline { return scan }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }

        private func scan(collectAll: Bool) -> Scan {
            var context = Context(deadline: Date().addingTimeInterval(scanTimeLimit))
            for window in context.elements(app, kAXWindowsAttribute) {
                visit(window, depth: 0, collectAll: collectAll, context: &context)
            }
            context.scan.match = StopButtonMatcher.pick(context.scan.candidates)
            return context.scan
        }

        private func visit(_ element: AXUIElement, depth: Int, collectAll: Bool, context: inout Context) {
            guard depth < 100, context.budget > 0, !context.scan.unresponsive, Date() < context.deadline else { return }
            context.budget -= 1
            let children = context.elements(element, kAXChildrenAttribute)
            for (index, child) in children.enumerated() {
                if context.string(child, kAXRoleAttribute) == (kAXButtonRole as String) {
                    context.scan.buttonsSeen += 1
                    let button = AXButtonInfo(
                        title: context.string(child, kAXTitleAttribute),
                        label: context.string(child, kAXDescriptionAttribute),
                        help: context.string(child, kAXHelpAttribute),
                        classes: context.strings(child, "AXDOMClassList")
                    )
                    // Reading sibling subtrees is expensive, so only do it for plausible buttons.
                    let plausible = StopButtonMatcher.hasStopLabel(button) || StopButtonMatcher.hasStopButtonClasses(button)
                    if plausible || collectAll {
                        var siblingClasses = Set<String>()
                        if plausible {
                            for (otherIndex, sibling) in children.enumerated() where otherIndex != index {
                                context.collectClasses(sibling, depth: 3, into: &siblingClasses)
                            }
                        }
                        context.scan.elements.append(child)
                        context.scan.candidates.append(StopButtonCandidate(button: button, siblingClasses: siblingClasses))
                    }
                }
                visit(child, depth: depth + 1, collectAll: collectAll, context: &context)
            }
        }
    }

    /// Attribute reads for one scan, with its time limit, element budget and hang detection.
    private struct Context {
        let deadline: Date
        var budget = 40_000
        var scan = Scan()

        init(deadline: Date) {
            self.deadline = deadline
        }

        mutating func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !scan.unresponsive, Date() < deadline else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            if error == .cannotComplete { scan.unresponsive = true }
            return error == .success ? value : nil
        }

        mutating func string(_ element: AXUIElement, _ attribute: String) -> String? {
            value(element, attribute) as? String
        }

        mutating func strings(_ element: AXUIElement, _ attribute: String) -> [String] {
            (value(element, attribute) as? [String]) ?? []
        }

        mutating func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
            guard let array = value(element, attribute) as? [AnyObject] else { return [] }
            return array.map { $0 as! AXUIElement }
        }

        mutating func collectClasses(_ element: AXUIElement, depth: Int, into classes: inout Set<String>) {
            classes.formUnion(strings(element, "AXDOMClassList"))
            guard depth > 0 else { return }
            for child in elements(element, kAXChildrenAttribute) {
                collectClasses(child, depth: depth - 1, into: &classes)
            }
        }
    }
}
