import Foundation

// Native, local-only Claude Code integration. Never calls Claude APIs, reads
// credentials or starts a model turn. Reads/writes ONLY user statusLine config.
enum ClaudeLinkState: Equatable {
    case missingHelper
    case notConfigured
    case customStatusLine
    case linked
    case linkedWithBridge
    case invalidSettings

    var isLinked: Bool { self == .linked || self == .linkedWithBridge }
}

enum ClaudeLinkError: LocalizedError {
    case helperMissing
    case malformedSettings
    case incompatibleStatusLine
    case unreadableSettings

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "LLMPulseIngest non è installato. Reinstalla LLMPulse."
        case .malformedSettings:
            return "settings.json non è JSON valido. Nessuna modifica effettuata."
        case .incompatibleStatusLine:
            return "Status line non supportata: configurazione non modificata."
        case .unreadableSettings:
            return "Impossibile leggere le impostazioni Claude. Nessuna modifica effettuata."
        }
    }
}

enum ClaudeStatusLineManager {
    private static let bridgePrefix = "llmpulse-statusline-bridge-"

    static func helperInApp(_ app: URL = Bundle.main.bundleURL) -> URL {
        app.appendingPathComponent("Contents/MacOS/LLMPulseIngest")
    }

    private static func settingsFile(home: URL) -> URL {
        home.appendingPathComponent(".claude/settings.json")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func settings(home: URL) throws -> (document: [String: Any], original: Data?) {
        let file = settingsFile(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else { return ([:], nil) }
        let content: Data
        do { content = try Data(contentsOf: file) }
        catch { throw ClaudeLinkError.unreadableSettings }
        guard let decoded = try? JSONSerialization.jsonObject(with: content) as? [String: Any] else {
            throw ClaudeLinkError.malformedSettings
        }
        return (decoded, content)
    }

    private static func statusCommand(in document: [String: Any]) throws -> String? {
        guard let value = document["statusLine"] else { return nil }
        guard let config = value as? [String: Any],
              (config["type"] as? String) == "command",
              let command = config["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeLinkError.incompatibleStatusLine
        }
        return command
    }

    private static func hasOurCommand(_ command: String, helper: URL) -> ClaudeLinkState? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == shellQuote(helper.path) || trimmed == helper.path {
            return .linked
        }
        // We generate bridge filenames with the unique managed prefix.
        if trimmed.contains(bridgePrefix) && trimmed.contains(".sh") { return .linkedWithBridge }
        return nil
    }

    static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       helper: URL = helperInApp()) -> ClaudeLinkState {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return .missingHelper
        }
        do {
            let doc = try settings(home: home).document
            guard let command = try statusCommand(in: doc) else { return .notConfigured }
            return hasOurCommand(command, helper: helper) ?? .customStatusLine
        } catch {
            return .invalidSettings
        }
    }

    // This must be called only from a direct "Collega Claude Code" UI action.
    // Existing unrelated settings remain untouched. Existing custom statusLine
    // is run through a bridge that also sends JSON to our silent ingest helper.
    @discardableResult
    static func connect(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        helper: URL = helperInApp()) throws -> ClaudeLinkState {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helper.path) else { throw ClaudeLinkError.helperMissing }
        let current = try settings(home: home)
        let existing = try statusCommand(in: current.document)
        if let existing, let already = hasOurCommand(existing, helper: helper) {
            return already
        }

        let directory = settingsFile(home: home).deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        var createdBridge: URL?
        var newCommand = shellQuote(helper.path)
        if let existing {
            let bridge = directory.appendingPathComponent(
                bridgePrefix + UUID().uuidString + ".sh"
            )
            let originalBase64 = Data(existing.utf8).base64EncodedString()
            let script = """
            #!/bin/zsh
            # LLMPulse-managed bridge. No JSON payload is persisted.
            payload=$(/bin/cat)
            printf '%s' "$payload" | \(shellQuote(helper.path)) --silent >/dev/null 2>&1 || true
            original_command="$(printf '%s' '\(originalBase64)' | /usr/bin/base64 -D)"
            printf '%s' "$payload" | /bin/sh -c "$original_command"
            """
            guard fm.createFile(atPath: bridge.path, contents: Data((script + "\n").utf8),
                                attributes: [.posixPermissions: 0o700]) else {
                throw ClaudeLinkError.unreadableSettings
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)
            createdBridge = bridge
            newCommand = "/bin/zsh " + shellQuote(bridge.path)
        }

        var document = current.document
        var statusConfig = (document["statusLine"] as? [String: Any]) ?? [:]
        statusConfig["type"] = "command"
        statusConfig["command"] = newCommand
        document["statusLine"] = statusConfig
        let updated = try JSONSerialization.data(withJSONObject: document,
                                                 options: [.prettyPrinted, .sortedKeys])

        do {
            if let original = current.original {
                // Backup is created before settings are changed. Never overwrite one
                // from an earlier setup. A unique name also avoids sync conflicts.
                let backup = directory.appendingPathComponent(
                    "settings.json.llmpulse-backup-" + UUID().uuidString
                )
                try original.write(to: backup, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            let destination = settingsFile(home: home)
            try updated.write(to: destination, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            if let createdBridge { try? fm.removeItem(at: createdBridge) }
            throw error
        }
        return createdBridge == nil ? .linked : .linkedWithBridge
    }
}
