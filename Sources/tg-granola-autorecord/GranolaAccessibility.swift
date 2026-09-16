import AppKit
import ApplicationServices
import AutorecordCore

/// Finds and presses Granola's "Stop transcript" button through the Accessibility API.
enum GranolaAccessibility {
    static func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func pressStopButton(bringToFront: () -> Void) -> ButtonPressResult {
        guard isTrusted(prompt: false) else { return .notTrusted }
        guard let app = appElement() else { return .granolaNotRunning }

        var scan = findStopButton(in: app, timeout: 3)
        if scan.match == nil {
            // The note window may be closed or hidden. Opening Granola shows it again.
            bringToFront()
            scan = findStopButton(in: app, timeout: 6)
        }
        guard let index = scan.match else { return .notFound(buttonsSeen: scan.elements.count) }
        let error = AXUIElementPerformAction(scan.elements[index], kAXPressAction as CFString)
        return error == .success ? .pressed : .failed(code: error.rawValue)
    }

    /// Human-readable list of every button Granola exposes, for checking the matcher against a new Granola version.
    static func dump() -> String {
        guard isTrusted(prompt: true) else {
            return "No Accessibility permission. Grant it to the app that runs this command, then retry."
        }
        guard let app = appElement() else { return "Granola is not running." }
        let scan = findStopButton(in: app, timeout: 3, collectAll: true)
        var lines = ["\(scan.elements.count) buttons, stop button match: \(scan.match.map { "#\($0)" } ?? "none")"]
        for (index, candidate) in scan.candidates.enumerated() {
            let button = candidate.button
            let names = [button.title, button.label, button.help].compactMap { $0 }.filter { !$0.isEmpty }
            let marker = index == scan.match ? "=> " : "   "
            lines.append("\(marker)#\(index) names=\(names) classes=\(button.classes.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tree walking

    private struct Scan {
        var elements: [AXUIElement] = []
        var candidates: [StopButtonCandidate] = []
        var match: Int?
    }

    private static func appElement() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Granola.bundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)
        // Electron builds the web content's accessibility tree only when asked to.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return element
    }

    /// Chromium fills in the tree asynchronously after `AXManualAccessibility` is set, so poll for a while.
    private static func findStopButton(in app: AXUIElement, timeout: TimeInterval, collectAll: Bool = false) -> Scan {
        var scan = Scan()
        _ = waitUntil(timeout: timeout, interval: 0.5) {
            scan = self.scan(app, collectAll: collectAll)
            return scan.match != nil
        }
        return scan
    }

    private static func scan(_ app: AXUIElement, collectAll: Bool) -> Scan {
        var scan = Scan()
        var budget = 40_000
        for window in elements(app, kAXWindowsAttribute) {
            visit(window, depth: 0, budget: &budget, collectAll: collectAll, scan: &scan)
        }
        scan.match = StopButtonMatcher.pick(scan.candidates)
        return scan
    }

    private static func visit(_ element: AXUIElement, depth: Int, budget: inout Int, collectAll: Bool, scan: inout Scan) {
        guard depth < 100, budget > 0 else { return }
        budget -= 1
        let children = elements(element, kAXChildrenAttribute)
        for (index, child) in children.enumerated() {
            if string(child, kAXRoleAttribute) == (kAXButtonRole as String) {
                let button = buttonInfo(child)
                // Reading sibling subtrees is expensive, so only do it for plausible buttons.
                let plausible = StopButtonMatcher.hasStopLabel(button)
                    || StopButtonMatcher.hasStopButtonClasses(button)
                if plausible || collectAll {
                    var siblingClasses = Set<String>()
                    if plausible {
                        for (otherIndex, sibling) in children.enumerated() where otherIndex != index {
                            collectClasses(sibling, depth: 3, into: &siblingClasses)
                        }
                    }
                    scan.elements.append(child)
                    scan.candidates.append(StopButtonCandidate(button: button, siblingClasses: siblingClasses))
                }
            }
            visit(child, depth: depth + 1, budget: &budget, collectAll: collectAll, scan: &scan)
        }
    }

    private static func collectClasses(_ element: AXUIElement, depth: Int, into classes: inout Set<String>) {
        classes.formUnion(stringArray(element, "AXDOMClassList"))
        guard depth > 0 else { return }
        for child in elements(element, kAXChildrenAttribute) {
            collectClasses(child, depth: depth - 1, into: &classes)
        }
    }

    private static func buttonInfo(_ element: AXUIElement) -> AXButtonInfo {
        AXButtonInfo(
            title: string(element, kAXTitleAttribute),
            label: string(element, kAXDescriptionAttribute),
            help: string(element, kAXHelpAttribute),
            classes: stringArray(element, "AXDOMClassList")
        )
    }

    // MARK: - Attribute access

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func stringArray(_ element: AXUIElement, _ attribute: String) -> [String] {
        (value(element, attribute) as? [String]) ?? []
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let array = value(element, attribute) as? [AnyObject] else { return [] }
        return array.map { $0 as! AXUIElement }
    }
}
