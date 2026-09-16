import Foundation

/// Clock and sleep in one place, so tests can run minutes of agent time instantly.
public protocol TimeSource {
    var now: Date { get }
    func sleep(seconds: TimeInterval)
}

/// Wall-clock time as of launch, advanced by a monotonic clock that keeps counting through sleep.
/// Adjusting the system clock therefore cannot stall or skip the agent's timers.
public final class SystemTime: TimeSource {
    private let wallAtStart = Date()
    private let monotonicAtStart = SystemTime.monotonicSeconds()

    public init() {}

    public var now: Date {
        wallAtStart.addingTimeInterval(SystemTime.monotonicSeconds() - monotonicAtStart)
    }

    public func sleep(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
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
