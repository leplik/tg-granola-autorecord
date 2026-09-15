import Foundation

/// The accessibility attributes this tool reads from a button in Granola's window.
public struct AXButtonInfo: Equatable, Sendable {
    public var title: String?
    public var label: String?
    public var help: String?
    /// DOM classes that Chromium exposes as `AXDOMClassList`.
    public var classes: [String]

    public init(title: String? = nil, label: String? = nil, help: String? = nil, classes: [String] = []) {
        self.title = title
        self.label = label
        self.help = help
        self.classes = classes
    }
}

public struct StopButtonCandidate: Equatable, Sendable {
    public var button: AXButtonInfo
    /// DOM classes found on the button's siblings and their close descendants.
    public var siblingClasses: Set<String>

    public init(button: AXButtonInfo, siblingClasses: Set<String>) {
        self.button = button
        self.siblingClasses = siblingClasses
    }
}

/// Decides which button in Granola's note view is "Stop transcript".
///
/// Granola renders it as an icon-only button whose "Stop transcript" text lives in a hover tooltip,
/// so today it has no accessible name. The matcher accepts an explicit label first, in case Granola
/// adds one, and otherwise falls back to the button's Tailwind classes next to the transcript pill.
public enum StopButtonMatcher {
    static let labelNeedles = ["stop transcript", "stop transcribing"]
    /// Classes of the trailing half of the transcript pill (`joined: "trailing"`).
    static let stopButtonClasses: Set<String> = ["min-w-10", "pr-[3px]", "pl-0"]
    /// Class of the leading half, the show/hide transcript button with the waveform.
    static let transcriptPillClass = "min-w-[48px]"

    public static func hasStopLabel(_ button: AXButtonInfo) -> Bool {
        [button.title, button.label, button.help].contains { text in
            guard let text = text?.lowercased() else { return false }
            return labelNeedles.contains { text.contains($0) }
        }
    }

    /// Cheap pre-check on the button alone, before its siblings are read.
    public static func hasStopButtonClasses(_ button: AXButtonInfo) -> Bool {
        stopButtonClasses.isSubset(of: Set(button.classes))
    }

    public static func looksLikeStopButton(_ candidate: StopButtonCandidate) -> Bool {
        hasStopButtonClasses(candidate.button) && candidate.siblingClasses.contains(transcriptPillClass)
    }

    /// Returns the index of the button to press, or nil when there is no single unambiguous match.
    /// Pressing nothing is always safer than pressing the wrong button.
    public static func pick(_ candidates: [StopButtonCandidate]) -> Int? {
        let labeled = candidates.indices.filter { hasStopLabel(candidates[$0].button) }
        if labeled.count == 1 { return labeled[0] }
        if labeled.count > 1 { return nil }
        let structural = candidates.indices.filter { looksLikeStopButton(candidates[$0]) }
        return structural.count == 1 ? structural[0] : nil
    }
}
