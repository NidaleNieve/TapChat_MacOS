import Foundation

// A provider's 5-hour window, as each CLI last reported it.
struct Usage: Codable, Equatable {
    var provider: Provider
    var fiveHourPercent: Double
    var resetsAt: Date?
    // Out of the 5-hour or the weekly allowance right now.
    var limitReached: Bool
    var checkedAt = Date()

    // rate_limit_event.rate_limit_info from `claude -p` (utilization is 0-1).
    init?(claude info: [String: Any]) {
        guard let windows = info["unifiedWindows"] as? [String: Any],
              let five = windows["five_hour"] as? [String: Any] else { return nil }
        provider = .claude
        fiveHourPercent = ((five["utilization"] as? Double) ?? 0) * 100
        resetsAt = (five["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let rejected = { (w: Any?) in ((w as? [String: Any])?["status"] as? String).map { $0 != "allowed" && $0 != "allowed_warning" } ?? false }
        limitReached = rejected(five) || rejected(windows["seven_day"]) || (info["status"] as? String == "rejected")
    }

    // rateLimits from the Codex app-server (usedPercent is 0-100).
    init?(codex limits: [String: Any]) {
        guard let primary = limits["primary"] as? [String: Any] else { return nil }
        provider = .codex
        fiveHourPercent = (primary["usedPercent"] as? Double) ?? 0
        resetsAt = (primary["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let secondary = ((limits["secondary"] as? [String: Any])?["usedPercent"] as? Double) ?? 0
        limitReached = !(limits["rateLimitReachedType"] is NSNull || limits["rateLimitReachedType"] == nil)
            || fiveHourPercent >= 100 || secondary >= 100
    }

    // A reading from before the window reset says nothing about now.
    var isCurrent: Bool { (resetsAt ?? .distantFuture) > Date() }
    var isExhausted: Bool { isCurrent && limitReached }
    var isHigh: Bool { isCurrent && (fiveHourPercent >= 90 || limitReached) }

    var summary: String {
        let pct = "\(provider.name) \(Int(fiveHourPercent.rounded()))%"
        guard let resetsAt else { return pct }
        let f = DateFormatter()
        f.timeStyle = .short
        return limitReached ? "\(provider.name) limit reached · resets \(f.string(from: resetsAt))" : "\(pct) of 5-hour limit · resets \(f.string(from: resetsAt))"
    }
}
