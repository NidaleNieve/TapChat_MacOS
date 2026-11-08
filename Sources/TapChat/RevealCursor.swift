import Foundation

// How much of a streaming answer is shown. Each frame shows a few more
// characters without counting or copying the whole answer: it keeps its
// place in the text. (Counting characters is a walk over the whole string,
// which, 60 times a second, added up on long answers.)
struct RevealCursor {
    private(set) var shown = ""
    private var target = ""
    // In `target`: where `shown` ends, and how many characters follow.
    private var position = "".startIndex
    private var remaining = 0

    var isCaughtUp: Bool { remaining == 0 }

    // The full text so far. Usually it only grew; when a CLI rewrites it, what
    // was shown is kept up to where the two still agree.
    mutating func update(_ value: String) {
        guard value != target else { return }
        let had = shown.utf8.count
        if value.utf8.count >= had, value.utf8.starts(with: shown.utf8),
           let p = value.utf8.index(value.utf8.startIndex, offsetBy: had).samePosition(in: value) {
            position = p
        } else {
            // Rare: walk both to the first character that differs.
            var i = shown.startIndex, j = value.startIndex
            while i < shown.endIndex, j < value.endIndex, shown[i] == value[j] {
                i = shown.index(after: i)
                j = value.index(after: j)
            }
            shown = String(shown[..<i])
            position = j
        }
        target = value
        remaining = value.distance(from: position, to: value.endIndex)
    }

    // Shows more: a fourteenth of what's left (at least one character), so
    // it never lags much and moves evenly. False when there was nothing to show.
    mutating func advance() -> Bool {
        guard remaining > 0 else { return false }
        let step = max(1, (remaining + 13) / 14)
        let end = target.index(position, offsetBy: step)
        shown += target[position..<end]
        position = end
        remaining -= step
        return true
    }
}
