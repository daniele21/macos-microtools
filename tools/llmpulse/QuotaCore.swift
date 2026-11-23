import Foundation

// Provider-neutral quota contract. Percentages are USED in upstream responses,
// but LLMPulse consistently renders REMAINING capacity.
enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude, antigravity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        }
    }
    var source: String {
        switch self {
        case .codex: return "Codex App Server"
        case .claude: return "Claude status line"
        case .antigravity: return "Antigravity CLI"
        }
    }
}

struct QuotaWindow: Codable, Identifiable {
    let id: String
    let name: String
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    var status: String {
        if remainingPercent <= 10 { return "critical" }
        if remainingPercent <= 25 { return "warning" }
        return "healthy"
    }

    func resetDescription(now: Date = Date()) -> String {
        guard let resetsAt else { return "Reset non disponibile" }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        if seconds <= 0 { return "Reset da verificare" }
        if seconds >= 86400 {
            return "tra \(seconds / 86400)g \(seconds % 86400 / 3600)h"
        }
        if seconds >= 3600 { return "tra \(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "tra \(max(1, seconds / 60))m"
    }
}

struct QuotaSnapshot: Codable {
    let provider: LLMProvider
    let windows: [QuotaWindow]
    let capturedAt: Date

    func isFresh(now: Date = Date(), ttl: TimeInterval = 900) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= -60 && age <= ttl
    }
}

enum QuotaParseError: Error, LocalizedError {
    case invalidResponse, missingLimits, providerFailure

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Formato risposta non riconosciuto"
        case .missingLimits: return "Quote non disponibili per questo account"
        case .providerFailure: return "Il provider non ha restituito le quote"
        }
    }
}

enum QuotaParser {
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let value = raw as? [String: Any] else { throw QuotaParseError.invalidResponse }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        guard let num = value as? NSNumber else { return nil }
        // NSNumber may also represent a JSON boolean: never interpret it as 0/1%.
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let value = num.doubleValue
        return value.isFinite ? value : nil
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let value = number(value), (0...100).contains(value) else { return nil }
        return value
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let value = number(value), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private static func iso(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func cadence(_ minutes: Double?) -> String {
        guard let minutes, minutes > 0 else { return "Quota" }
        if minutes >= 10080 && Int(minutes) % 10080 == 0 {
            return "\(Int(minutes) / 10080) sett."
        }
        if minutes >= 60 && Int(minutes) % 60 == 0 { return "\(Int(minutes) / 60)h" }
        return "\(Int(minutes))m"
    }

    // Codex RPC: {"id": 1, "result": {"rateLimitsByLimitId": {...}}}
    // Fallback to rateLimits for older clients. Never sum independently-metered buckets.
    static func codex(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        if root["error"] != nil { throw QuotaParseError.providerFailure }
        guard let result = root["result"] as? [String: Any] else {
            throw QuotaParseError.invalidResponse
        }
        let buckets: [(String, [String: Any])]
        if let multi = result["rateLimitsByLimitId"] as? [String: [String: Any]], !multi.isEmpty {
            buckets = multi.keys.sorted().compactMap { key in multi[key].map { (key, $0) } }
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [(single["limitId"] as? String ?? "codex", single)]
        } else {
            throw QuotaParseError.missingLimits
        }
        var windows: [QuotaWindow] = []
        for (id, bucket) in buckets {
            let givenName = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let title = givenName ?? (id == "codex" ? "Codex" : id)
            for (kind, suffix) in [("primary", "1"), ("secondary", "2")] {
                guard let window = bucket[kind] as? [String: Any],
                      let used = percent(window["usedPercent"]) else { continue }
                let period = cadence(number(window["windowDurationMins"]))
                windows.append(QuotaWindow(
                    id: "\(id):\(kind)",
                    name: "\(title) · \(period)",
                    usedPercent: used,
                    resetsAt: epoch(window["resetsAt"])
                ))
                _ = suffix
            }
        }
        guard !windows.isEmpty else { throw QuotaParseError.missingLimits }
        return windows
    }

    // Claude Code receives stdin JSON in a user-configured statusLine command.
    // Rate limits only appear after Claude's first API response. The statusline
    // contains NO additional weekly model-specific quotas; do not invent them.
    static func claude(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        guard let limits = root["rate_limits"] as? [String: Any] else {
            throw QuotaParseError.missingLimits
        }
        var windows: [QuotaWindow] = []
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7 giorni")] {
            guard let raw = limits[key] as? [String: Any],
                  let used = percent(raw["used_percentage"]) else { continue }
            windows.append(QuotaWindow(id: key, name: label, usedPercent: used,
                                       resetsAt: epoch(raw["resets_at"])))
        }
        // Spend limit is a separate gateway budget, not a subscription quota.
        if let spend = limits["spend_limit"] as? [String: Any],
           let used = percent(spend["used_percentage"]) {
            windows.append(QuotaWindow(id: "spend_limit", name: "Budget gateway",
                                       usedPercent: used, resetsAt: epoch(spend["resets_at"])))
        }
        guard !windows.isEmpty else { throw QuotaParseError.missingLimits }
        return windows
    }

    // agy -p /usage --output-format json: command.data.groups[].buckets[]
    // remaining_fraction is already the REMAINING proportion, not utilization.
    static func antigravity(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        guard (root["status"] as? String)?.uppercased() == "SUCCESS" else {
            throw QuotaParseError.providerFailure
        }
        guard let command = root["command"] as? [String: Any],
              (command["name"] as? String) == "usage",
              let contents = command["data"] as? [String: Any],
              let groups = contents["groups"] as? [[String: Any]] else {
            throw QuotaParseError.invalidResponse
        }
        var windows: [QuotaWindow] = []
        for group in groups {
            let name = (group["name"] as? String) ?? "Modelli"
            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                if let enabled = bucket["enabled"] as? Bool, !enabled { continue }
                guard let fraction = number(bucket["remaining_fraction"]),
                      (0...1).contains(fraction) else { continue }
                let id = (bucket["id"] as? String) ?? UUID().uuidString
                let period = (bucket["window"] as? String) == "weekly" ? "7 giorni" :
                    ((bucket["name"] as? String) ?? "Quota")
                windows.append(QuotaWindow(
                    id: id, name: "\(name) · \(period)",
                    usedPercent: (1 - fraction) * 100,
                    resetsAt: iso(bucket["reset_time"])
                ))
            }
        }
        guard !windows.isEmpty else { throw QuotaParseError.missingLimits }
        return windows
    }
}

// A private, bounded, credential-free snapshot. Never persist the full statusline
// payload, which may contain paths, session IDs or other sensitive data.
enum QuotaFiles {
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/LLMPulse", isDirectory: true)
    }
    static func claudeFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        directory(home: home).appendingPathComponent("claude-quota.json")
    }

    static func write(_ snapshot: QuotaSnapshot, at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(snapshot)
        guard encoded.count <= 32 * 1024 else { throw QuotaParseError.invalidResponse }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: encoded,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw QuotaParseError.invalidResponse
        }
        do {
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func read(at url: URL, provider: LLMProvider) -> QuotaSnapshot? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= 32 * 1024,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data),
              snapshot.provider == provider else { return nil }
        return snapshot
    }
}
