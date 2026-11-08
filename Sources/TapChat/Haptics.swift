import AppKit

// Trackpad haptics through the public API: three fixed patterns, no
// intensity, felt only with a finger on a Force Touch trackpad. (A private
// API allows more, but crashes on Apple Silicon.) So: light, a little
// irregular, and one clear thump at the end.
enum Haptics {
    private static var performer: NSHapticFeedbackPerformer { NSHapticFeedbackManager.defaultPerformer }
    private static var pendingDone: DispatchWorkItem?
    // Only while the window is on screen: nothing is felt for a hidden chat.
    static var windowVisible = false {
        didSet { if !windowVisible { cancelDone() } }
    }
    private static var active: Bool { Settings.haptics && windowVisible }

    // While an answer appears: quick, uneven little taps, mostly the lightest
    // pattern and now and then a firmer one, timed to the redraw.
    static func tick() {
        guard active else { return }
        let firmer = Double.random(in: 0..<1) < 0.2
        performer.perform(firmer ? .generic : .alignment, performanceTime: .drawCompleted)
    }

    // The gap before the next tap: short and uneven.
    static func nextGap() -> TimeInterval { Double.random(in: 0.03...0.09) }
    // Some due taps are skipped, so it never settles into a rhythm.
    static func shouldSkip() -> Bool { Double.random(in: 0..<1) < 0.15 }

    // The answer is done: one hit, 0.15 s after the last tap. A single
    // levelChange is the strongest one the public API has (two patterns in a
    // row were felt as two taps).
    static func done(after lastTick: Date) {
        log("haptics done requested active=\(active) setting=\(Settings.haptics) visible=\(windowVisible)")
        guard active else { return }
        cancelDone()
        let delay = max(0.15, 0.15 - Date().timeIntervalSince(lastTick))
        let work = DispatchWorkItem {
            pendingDone = nil
            log("haptics done fires active=\(active)")
            guard active else { return }
            // levelChange: the strongest pattern the public API has.
            performer.perform(.levelChange, performanceTime: .now)
        }
        pendingDone = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func cancelDone() {
        if pendingDone != nil { log("haptics done cancelled") }
        pendingDone?.cancel()
        pendingDone = nil
    }

    // Copied, forked: one clear tap.
    static func confirm() {
        guard active else { return }
        performer.perform(.levelChange, performanceTime: .now)
    }
}
