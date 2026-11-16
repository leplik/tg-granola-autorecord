import Foundation

/// One pass over Granola's windows, as the Accessibility layer sees it.
public struct StopButtonScan: Equatable, Sendable {
    /// Exactly one button matched `StopButtonMatcher`.
    public var found: Bool
    /// The matched button lists AXPress. Chromium lists it only in its complete accessibility mode,
    /// and in the basic mode it ignores a press, although the call reports success.
    public var pressable: Bool
    public var buttonsSeen: Int
    /// Granola answered with kAXErrorCannotComplete, which usually means it is hung.
    public var unresponsive: Bool

    public init(found: Bool, pressable: Bool, buttonsSeen: Int, unresponsive: Bool = false) {
        self.found = found
        self.pressable = pressable
        self.buttonsSeen = buttonsSeen
        self.unresponsive = unresponsive
    }
}

/// Granola's window and the app focus, as `StopButtonPress` needs them.
/// Implemented with the Accessibility API in the executable.
public protocol StopButtonSurface: AnyObject {
    /// Scans Granola's windows once.
    func scan() -> StopButtonScan
    /// Presses the button that the latest scan found. Returns the AXError code; 0 means success.
    func pressFoundButton() -> Int32
    /// Bundle identifier of the app that has the focus.
    func frontmostAppID() -> String?
    /// Brings the app with this bundle identifier to the front.
    func activate(bundleID: String)
}

/// Presses Granola's stop button, and shows Granola for a moment when its page does not accept presses.
///
/// Electron turns on its complete accessibility tree 2 s after `AXManualAccessibility` is set. Chromium then
/// applies that mode only to a page that is on screen. A Granola window behind other windows keeps a basic
/// tree: the stop button is visible to Accessibility, but it has no AXPress and a press does nothing.
/// So a button that does not accept presses is never pressed. The sequence waits for Electron first,
/// and only then shows Granola. After the press it gives the focus back to the app the user was in.
public struct StopButtonPress {
    /// How long the first search waits for the button. Electron builds its tree after 2 s.
    public static let firstSearch: TimeInterval = 5
    /// How long a found button may take to accept presses while Granola stays in the background.
    /// This covers Electron's 2 s delay when Granola's window is on screen.
    public static let pressableWait: TimeInterval = 3
    /// How long to wait for a button that accepts presses after showing Granola.
    public static let shownWait: TimeInterval = 6
    /// How long to wait for the stop button to go away before giving the focus back.
    public static let settleWait: TimeInterval = 2
    public static let scanInterval: TimeInterval = 0.5

    private let surface: StopButtonSurface
    private let time: TimeSource
    private let log: (String) -> Void

    public init(surface: StopButtonSurface, time: TimeSource, log: @escaping (String) -> Void) {
        self.surface = surface
        self.time = time
        self.log = log
    }

    public func run() -> ButtonPressResult {
        let previousApp = surface.frontmostAppID()

        var scan = search(for: Self.firstSearch) { $0.found }
        if scan.found && !scan.pressable {
            log("the stop button does not accept presses yet, waiting for Granola's accessibility tree")
            scan = search(for: Self.pressableWait) { $0.found && $0.pressable }
        }

        var shown = false
        if !(scan.found && scan.pressable) && !scan.unresponsive {
            // The note window may also be closed. Opening Granola shows it again.
            log("showing Granola, because its stop button accepts presses only while its window is on screen")
            surface.activate(bundleID: Granola.bundleID)
            shown = true
            scan = search(for: Self.shownWait) { $0.found && $0.pressable }
        }

        let result: ButtonPressResult
        if !scan.found {
            result = .notFound(buttonsSeen: scan.buttonsSeen)
        } else if !scan.pressable {
            result = .notPressable
        } else {
            let code = surface.pressFoundButton()
            result = code == 0 ? .pressed : .failed(code: code)
        }

        if shown {
            if case .pressed = result {
                // Let Granola handle the press while its window is still in front.
                _ = poll(timeout: Self.settleWait, interval: Self.scanInterval, time: time) { !surface.scan().found }
            }
            giveFocusBack(to: previousApp)
        }
        return result
    }

    /// Scans until `done` holds, Granola stops responding, or `timeout` passes. Returns the last scan.
    private func search(for timeout: TimeInterval, until done: (StopButtonScan) -> Bool) -> StopButtonScan {
        let deadline = time.now.addingTimeInterval(timeout)
        var scan = surface.scan()
        while !done(scan) && !scan.unresponsive && time.now < deadline {
            time.sleep(seconds: Self.scanInterval)
            scan = surface.scan()
        }
        return scan
    }

    /// Leaves the focus alone if Granola was already in front, or if the user switched apps meanwhile.
    private func giveFocusBack(to previousApp: String?) {
        guard let previousApp, previousApp != Granola.bundleID,
              surface.frontmostAppID() == Granola.bundleID else { return }
        log("giving the focus back to \(previousApp)")
        surface.activate(bundleID: previousApp)
    }
}
