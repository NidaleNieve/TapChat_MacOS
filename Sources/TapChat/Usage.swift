import Foundation

// A provider's 5-hour and weekly windows, as each CLI last reported them.
struct Usage: Codable, Equatable {
    var provider: Provider
    var fiveHourPercent: Double
    var resetsAt: Date?
    var weekPercent: Double?
    var weekResetsAt: Date?
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
        if let week = windows["seven_day"] as? [String: Any] {
            weekPercent = (week["utilization"] as? Double).map { $0 * 100 }
            weekResetsAt = (week["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        let rejected = { (w: Any?) in ((w as? [String: Any])?["status"] as? String).map { $0 != "allowed" && $0 != "allowed_warning" } ?? false }
        limitReached = rejected(five) || rejected(windows["seven_day"]) || (info["status"] as? String == "rejected")
    }

    // rateLimits from the Codex app-server (usedPercent is 0-100).
    init?(codex limits: [String: Any]) {
        guard let primary = limits["primary"] as? [String: Any] else { return nil }
        provider = .codex
        fiveHourPercent = (primary["usedPercent"] as? Double) ?? 0
        resetsAt = (primary["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let week = limits["secondary"] as? [String: Any]
        weekPercent = week?["usedPercent"] as? Double
        weekResetsAt = (week?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let secondary = weekPercent ?? 0
        limitReached = !(limits["rateLimitReachedType"] is NSNull || limits["rateLimitReachedType"] == nil)
            || fiveHourPercent >= 100 || secondary >= 100
    }

    // A reading from before the window reset says nothing about now.
    var isCurrent: Bool { (resetsAt ?? .distantFuture) > Date() }
    var weekIsCurrent: Bool { (weekResetsAt ?? .distantFuture) > Date() }
    var isExhausted: Bool { (isCurrent || weekIsCurrent) && limitReached }
    // Shown (in orange) from 90% of either window; red from 95% or at the limit.
    var fiveHourShown: Double? { isCurrent && fiveHourPercent >= 90 ? fiveHourPercent : nil }
    var weekShown: Double? { weekIsCurrent ? weekPercent.flatMap { $0 >= 90 ? $0 : nil } : nil }
    var isHigh: Bool { fiveHourShown != nil || weekShown != nil || isExhausted }
    var isCritical: Bool { isExhausted || (fiveHourShown ?? 0) >= 95 || (weekShown ?? 0) >= 95 }

    // The badge: "92%", "week 91%", or both.
    var badge: String {
        if isExhausted { return "limit" }
        return [fiveHourShown.map { "\(Int($0.rounded()))%" }, weekShown.map { "week \(Int($0.rounded()))%" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var summary: String {
        let f = DateFormatter()
        f.timeStyle = .short
        var s: String
        if let resetsAt, isCurrent {
            s = limitReached ? "\(provider.name) limit reached · resets \(f.string(from: resetsAt))"
                : "\(provider.name) \(Int(fiveHourPercent.rounded()))% of 5-hour limit · resets \(f.string(from: resetsAt))"
        } else if resetsAt != nil {
            // That 5-hour window is over: nothing used since (the next
            // message starts a new one, and brings fresh figures).
            s = "\(provider.name) 0% of 5-hour limit"
        } else {
            s = "\(provider.name) \(Int(fiveHourPercent.rounded()))%"
        }
        if let week = weekPercent, weekIsCurrent {
            f.dateStyle = .short
            s += "\n\(Int(week.rounded()))% of weekly limit" + (weekResetsAt.map { " · resets \(f.string(from: $0))" } ?? "")
        }
        return s
    }
}
