import AppKit

// Trackpad haptics through the public API: three fixed patterns, no
// intensity, felt only with a finger on a Force Touch trackpad. (A private
// API allows more, but crashes on Apple Silicon.) So: sparse and even.
enum Haptics {
    private static var performer: NSHapticFeedbackPerformer { NSHapticFeedbackManager.defaultPerformer }

    // While an answer appears: the lightest pattern, timed to the redraw so it
    // lands with the text.
    static func tick() {
        guard Settings.haptics else { return }
        performer.perform(.alignment, performanceTime: .drawCompleted)
    }

    // The answer is done: a short roll that ends firm.
    static func done() {
        guard Settings.haptics else { return }
        performer.perform(.alignment, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { performer.perform(.levelChange, performanceTime: .now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { performer.perform(.levelChange, performanceTime: .now) }
    }

    // Copied, forked: one clear tap.
    static func confirm() {
        guard Settings.haptics else { return }
        performer.perform(.levelChange, performanceTime: .now)
    }
}
