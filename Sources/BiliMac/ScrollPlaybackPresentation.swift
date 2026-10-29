import Foundation

/// Presentation only: moving the video must never replace the media item.
struct ScrollPlaybackPresentation: Equatable {
    private(set) var inlineVisible = true
    private(set) var dismissed = false
    var floating: Bool { !inlineVisible && !dismissed }

    mutating func updateVisibleFraction(_ fraction: CGFloat) {
        guard fraction.isFinite else { return }
        // Different entry/return thresholds prevent bouncing at the boundary.
        setInlineVisible(inlineVisible ? fraction > 0.2 : fraction >= 0.4)
    }

    mutating func setInlineVisible(_ visible: Bool) {
        inlineVisible = visible
        if visible { dismissed = false }
    }
    mutating func dismiss() { dismissed = true }
    mutating func reset() { self = Self() }
}
