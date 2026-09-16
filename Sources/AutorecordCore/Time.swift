import Foundation

/// Clock and sleep in one place, so tests can run minutes of agent time instantly.
public protocol TimeSource {
    var now: Date { get }
    func sleep(seconds: TimeInterval)
}

public struct SystemTime: TimeSource {
    public init() {}

    public var now: Date { Date() }

    public func sleep(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

/// Checks `condition` every `interval` until it holds or `timeout` passes.
public func poll(timeout: TimeInterval, interval: TimeInterval = 1, time: TimeSource, until condition: () -> Bool) -> Bool {
    let deadline = time.now.addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if time.now >= deadline { return false }
        time.sleep(seconds: interval)
    }
}
