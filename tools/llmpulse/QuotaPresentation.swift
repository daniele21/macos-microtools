import Foundation

// Pure presentation policy shared by macOS UI and Linux/macOS unit tests.
// A menu-bar number represents a real 5-hour quota, never a weekly fallback.
enum QuotaPresentation {
    static let automaticGroup = "automatic"

    static func group(of window: QuotaWindow, provider: LLMProvider) -> String {
        guard provider == .antigravity else { return provider.title }
        return String(window.name.components(separatedBy: " · ").first ?? "Modelli")
    }

    static func groups(in snapshot: QuotaSnapshot?) -> [String] {
        guard let snapshot, snapshot.provider == .antigravity else { return [] }
        var seen = Set<String>()
        return snapshot.windows.compactMap { window in
            let label = group(of: window, provider: .antigravity)
            return seen.insert(label).inserted ? label : nil
        }
    }

    static func isFiveHour(_ window: QuotaWindow) -> Bool {
        let name = window.name.lowercased()
        return window.id == "five_hour" ||
            name.contains("· 5h") ||
            name.contains("5 ore") ||
            name.contains("five hour")
    }

    static func isWeekly(_ window: QuotaWindow) -> Bool {
        let name = window.name.lowercased()
        return window.id == "seven_day" ||
            name.contains("7 giorni") ||
            name.contains("1 sett.") ||
            name.contains("weekly") ||
            name.contains("settimana")
    }

    static func isUsable(_ window: QuotaWindow, at now: Date) -> Bool {
        // A reset requires another provider observation: do not keep showing
        // old utilization as a live measurement after the reset boundary.
        guard let resetsAt = window.resetsAt else { return true }
        return resetsAt > now
    }

    static func fiveHour(_ snapshot: QuotaSnapshot?,
                         group preferred: String = automaticGroup,
                         at now: Date = Date()) -> QuotaWindow? {
        guard let snapshot, snapshot.isFresh(now: now) else { return nil }
        let windows = snapshot.windows.filter { isFiveHour($0) && isUsable($0, at: now) }
        if snapshot.provider == .antigravity, preferred != automaticGroup {
            return windows.first { group(of: $0, provider: .antigravity) == preferred }
        }
        // Real capacity is the limiting usable 5-hour bucket. Do not combine
        // quotas for different model families; tooltip exposes which was chosen.
        return windows.min {
            if $0.remainingPercent != $1.remainingPercent {
                return $0.remainingPercent < $1.remainingPercent
            }
            return $0.id < $1.id
        }
    }

    static func weekly(_ snapshot: QuotaSnapshot?,
                       matching fiveHour: QuotaWindow?,
                       group preferred: String = automaticGroup,
                       at now: Date = Date()) -> QuotaWindow? {
        guard let snapshot, snapshot.isFresh(now: now) else { return nil }
        var windows = snapshot.windows.filter { isWeekly($0) && isUsable($0, at: now) }
        if snapshot.provider == .antigravity {
            // If the user pinned a weekly-only model, it must not be mistaken
            // for a 5-hour quota. The 5-hour label stays unavailable.
            let groupName: String?
            if preferred != automaticGroup {
                groupName = preferred
            } else if let fiveHour {
                groupName = group(of: fiveHour, provider: .antigravity)
            } else {
                groupName = nil
            }
            guard let groupName else { return nil }
            windows = windows.filter { group(of: $0, provider: .antigravity) == groupName }
        } else if snapshot.provider == .codex, let fiveHour {
            let bucket = String(fiveHour.id.split(separator: ":").first ?? "")
            if !bucket.isEmpty {
                windows = windows.filter { $0.id.hasPrefix(bucket + ":") }
            }
        }
        return windows.min {
            if $0.remainingPercent != $1.remainingPercent {
                return $0.remainingPercent < $1.remainingPercent
            }
            return $0.id < $1.id
        }
    }

    static func usedLabel(_ window: QuotaWindow?, showRemaining: Bool) -> String {
        guard let window else { return "—" }
        let number = showRemaining ? window.remainingPercent : window.usedPercent
        return "\(Int(number.rounded()))%"
    }

    static func menuTooltip(provider: LLMProvider, snapshot: QuotaSnapshot?,
                            fiveHour: QuotaWindow?, showRemaining: Bool,
                            error: String? = nil, at now: Date = Date()) -> String {
        var lines = ["\(provider.title) · quota 5 ore"]
        if let fiveHour {
            lines.append("\(usedLabel(fiveHour, showRemaining: showRemaining)) \(showRemaining ? "disponibile" : "consumato")")
            if provider == .antigravity {
                lines.append("Gruppo: \(group(of: fiveHour, provider: provider))")
            }
            lines.append("Reset \(fiveHour.resetDescription(now: now))")
        } else if let snapshot, !snapshot.isFresh(now: now) {
            lines.append("Dati non aggiornati")
        } else {
            lines.append("Quota 5 ore non disponibile")
        }
        if let error, !error.isEmpty { lines.append(error) }
        return lines.joined(separator: "\n")
    }
}
