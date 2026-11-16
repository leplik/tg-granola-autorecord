import AutorecordCore
import XCTest

/// Granola's window and the app focus, controlled by the test.
final class FakeSurface: StopButtonSurface {
    /// The stop button is in Granola's accessibility tree.
    var buttonPresent = true
    /// The stop button appears only once Granola is shown, as when the note window is closed.
    var buttonAppearsWhenShown = false
    /// Whether the found button lists AXPress. By default only while Granola is shown,
    /// as with a Granola window behind other windows.
    var acceptsPress: (FakeSurface) -> Bool = { $0.granolaShown }
    var unresponsive = false
    var pressCode: Int32 = 0
    /// A successful press replaces the stop button with Resume, which has text and does not match.
    var pressRemovesButton = true
    var frontmost: String?
    /// Runs inside `pressFoundButton`, e.g. to simulate the user switching apps.
    var onPress: (() -> Void)?

    private(set) var granolaShown = false
    private(set) var presses = 0
    /// Presses on a button without AXPress. Chromium drops those silently.
    private(set) var ignoredPresses = 0
    private(set) var activations: [String] = []
    /// Whether the stop button was still there when the focus went back to the previous app.
    private(set) var buttonPresentAtFocusReturn: Bool?

    init(frontmost: String? = "ru.keepcoder.Telegram") {
        self.frontmost = frontmost
    }

    func scan() -> StopButtonScan {
        StopButtonScan(found: buttonPresent, pressable: buttonPresent && acceptsPress(self), buttonsSeen: 7, unresponsive: unresponsive)
    }

    func pressFoundButton() -> Int32 {
        presses += 1
        if !acceptsPress(self) { ignoredPresses += 1 }
        onPress?()
        if pressCode == 0 && pressRemovesButton { buttonPresent = false }
        return pressCode
    }

    func frontmostAppID() -> String? { frontmost }

    func activate(bundleID: String) {
        activations.append(bundleID)
        frontmost = bundleID
        if bundleID == Granola.bundleID {
            granolaShown = true
            if buttonAppearsWhenShown { buttonPresent = true }
        } else {
            buttonPresentAtFocusReturn = buttonPresent
        }
    }
}

final class StopButtonPressTests: XCTestCase {
    private let telegram = "ru.keepcoder.Telegram"

    private func run(_ surface: FakeSurface, time: FakeTime = FakeTime()) -> ButtonPressResult {
        StopButtonPress(surface: surface, time: time, log: { _ in }).run()
    }

    func testPressesAtOnceWhenTheButtonAcceptsPresses() {
        let surface = FakeSurface()
        surface.acceptsPress = { _ in true }
        XCTAssertEqual(run(surface), .pressed)
        XCTAssertEqual(surface.presses, 1)
        XCTAssertEqual(surface.activations, [])
    }

    func testWaitsForElectronBeforeShowingGranola() {
        // Granola's window is on screen, so Electron's complete tree arrives after 2 s.
        let time = FakeTime()
        let start = time.now
        let surface = FakeSurface()
        surface.acceptsPress = { _ in time.now.timeIntervalSince(start) >= 2 }
        XCTAssertEqual(run(surface, time: time), .pressed)
        XCTAssertEqual(surface.ignoredPresses, 0)
        XCTAssertEqual(surface.activations, [])
    }

    func testShowsGranolaWhenItsWindowIsBehindOtherWindows() {
        // The button is found at once in Chromium's basic tree, but it accepts presses only once shown.
        let surface = FakeSurface()
        XCTAssertEqual(run(surface), .pressed)
        XCTAssertEqual(surface.presses, 1)
        XCTAssertEqual(surface.ignoredPresses, 0)
        XCTAssertEqual(surface.activations, [Granola.bundleID, telegram])
        XCTAssertEqual(surface.buttonPresentAtFocusReturn, false)
    }

    func testShowsGranolaWhenNoButtonIsFound() {
        let surface = FakeSurface()
        surface.buttonPresent = false
        surface.buttonAppearsWhenShown = true
        XCTAssertEqual(run(surface), .pressed)
        XCTAssertEqual(surface.activations, [Granola.bundleID, telegram])
    }

    func testNeverPressesAButtonThatDoesNotAcceptPresses() {
        let surface = FakeSurface()
        surface.acceptsPress = { _ in false }
        XCTAssertEqual(run(surface), .notPressable)
        XCTAssertEqual(surface.presses, 0)
        XCTAssertEqual(surface.activations, [Granola.bundleID, telegram])
    }

    func testReportsAMissingButtonAndGivesTheFocusBack() {
        let surface = FakeSurface()
        surface.buttonPresent = false
        XCTAssertEqual(run(surface), .notFound(buttonsSeen: 7))
        XCTAssertEqual(surface.presses, 0)
        XCTAssertEqual(surface.activations, [Granola.bundleID, telegram])
    }

    func testGivesTheFocusBackEvenIfTheButtonStays() {
        let time = FakeTime()
        let before = time.now
        let surface = FakeSurface()
        surface.pressRemovesButton = false
        XCTAssertEqual(run(surface, time: time), .pressed)
        XCTAssertEqual(surface.activations, [Granola.bundleID, telegram])
        XCTAssertEqual(surface.buttonPresentAtFocusReturn, true)
        XCTAssertLessThan(
            time.now.timeIntervalSince(before),
            StopButtonPress.firstSearch + StopButtonPress.pressableWait + StopButtonPress.shownWait + StopButtonPress.settleWait
        )
    }

    func testLeavesTheFocusAloneWhenTheUserSwitchedApps() {
        let surface = FakeSurface()
        surface.onPress = { surface.frontmost = "com.apple.Safari" }
        XCTAssertEqual(run(surface), .pressed)
        XCTAssertEqual(surface.activations, [Granola.bundleID])
    }

    func testKeepsGranolaInFrontWhenItWasInFrontBefore() {
        let surface = FakeSurface(frontmost: Granola.bundleID)
        XCTAssertEqual(run(surface), .pressed)
        XCTAssertEqual(surface.activations, [Granola.bundleID])
    }

    func testDoesNotShowAHungGranola() {
        let surface = FakeSurface()
        surface.buttonPresent = false
        surface.unresponsive = true
        XCTAssertEqual(run(surface), .notFound(buttonsSeen: 7))
        XCTAssertEqual(surface.activations, [])
    }

    func testReportsAFailedPress() {
        let surface = FakeSurface()
        surface.acceptsPress = { _ in true }
        surface.pressCode = -25204
        XCTAssertEqual(run(surface), .failed(code: -25204))
        XCTAssertEqual(surface.activations, [])
    }
}
