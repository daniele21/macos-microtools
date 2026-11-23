import Foundation
#if os(macOS)
import Darwin
#endif

enum QuotaFetchError: LocalizedError {
    case commandMissing(String), failed(String), timeout, oversized, notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .commandMissing(let executable): return "\(executable) non installato o non trovato"
        case .failed(let message): return message
        case .timeout: return "Interrogazione scaduta; riprova manualmente"
        case .oversized: return "Risposta troppo grande"
        case .notConfigured(let message): return message
        }
    }
}

enum ExecutableLocator {
    static func find(_ name: String, override: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let specified = environment[override] {
            // A set override is authoritative, including an empty or invalid path.
            return valid(URL(fileURLWithPath: specified))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin"]
        for folder in search where folder.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if let found = valid(candidate) { return found }
        }
        return nil
    }

    private static func valid(_ file: URL) -> URL? {
        guard file.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: file.path) else {
            return nil
        }
        return file
    }
}

// Bounded child process helper: no shell interpolation and no inherited stdin.
// No OAuth/browser interaction is intentionally started by LLMPulse.
enum QuotaSubprocess {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 25,
                    environment: [String: String] = [:]) throws -> Data {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let output = Pipe()
        task.standardOutput = output
        let lock = NSLock()
        var captured = Data()
        var exceeded = false
        let finished = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            lock.lock()
            if captured.count + bytes.count <= 1024 * 1024 {
                captured.append(bytes)
            } else {
                exceeded = true
            }
            lock.unlock()
        }
        task.terminationHandler = { _ in finished.signal() }
        do { try task.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw QuotaFetchError.failed("Impossibile avviare \(executable.lastPathComponent)")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if task.isRunning { task.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut && task.isRunning {
                #if os(macOS)
                kill(task.processIdentifier, SIGKILL)
                #endif
            }
            output.fileHandleForReading.readabilityHandler = nil
            throw QuotaFetchError.timeout
        }
        _ = drained.wait(timeout: .now() + 1)
        output.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let data = captured
        let tooLarge = exceeded
        lock.unlock()
        if tooLarge { throw QuotaFetchError.oversized }
        if task.terminationStatus != 0 {
            throw QuotaFetchError.failed("\(executable.lastPathComponent) non ha restituito le quote; controlla il login")
        }
        return data
    }
}

enum CodexRPC {
    private static func message(_ object: [String: Any]) -> Data? {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        bytes.append(0x0A)
        return bytes
    }

    static func readRateLimits() throws -> Data {
        guard let executable = ExecutableLocator.find("codex", override: "LLMPULSE_CODEX_PATH") else {
            throw QuotaFetchError.commandMissing("Codex CLI")
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["app-server"]
        task.standardError = FileHandle.nullDevice
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var response: Data?
        var failure: String?
        var notified = false
        func finish(_ result: Data?, _ error: String?) {
            lock.lock()
            if !notified {
                response = result
                failure = error
                notified = true
                done.signal()
            }
            lock.unlock()
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let part = handle.availableData
            if part.isEmpty {
                handle.readabilityHandler = nil
                finish(nil, "Codex App Server ha chiuso la connessione")
                return
            }
            // Everything on this connection is JSONL; do not retain diagnostics.
            lock.lock()
            buffer.append(part)
            if buffer.count > 1024 * 1024 {
                lock.unlock()
                finish(nil, "Risposta Codex troppo grande")
                return
            }
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: 0..<newline))
                buffer.removeSubrange(0...newline)
            }
            lock.unlock()
            for line in lines {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = json["id"] as? Int else { continue }
                if id == 0 {
                    if json["error"] != nil {
                        finish(nil, "Handshake Codex rifiutato")
                    } else {
                        let initialized = Self.message(["method": "initialized", "params": [:]])
                        let read = Self.message(["method": "account/rateLimits/read", "id": 1])
                        if let initialized, let read {
                            try? input.fileHandleForWriting.write(contentsOf: initialized)
                            try? input.fileHandleForWriting.write(contentsOf: read)
                        } else {
                            finish(nil, "Errore protocollo Codex")
                        }
                    }
                } else if id == 1 {
                    finish(line, json["error"] == nil ? nil : "Limiti Codex non disponibili")
                }
            }
        }
        task.terminationHandler = { _ in finish(nil, "Codex App Server terminato") }
        do { try task.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw QuotaFetchError.failed("Impossibile avviare Codex App Server")
        }
        if let initialize = Self.message([
            "method": "initialize", "id": 0,
            "params": ["clientInfo": [
                "name": "llmpulse", "title": "LLMPulse", "version": "0.1.0"
            ]]
        ]) { try? input.fileHandleForWriting.write(contentsOf: initialize) }
        let completed = done.wait(timeout: .now() + 12) == .success
        output.fileHandleForReading.readabilityHandler = nil
        if task.isRunning { task.terminate() }
        try? input.fileHandleForWriting.close()
        if !completed { throw QuotaFetchError.timeout }
        if let failure { throw QuotaFetchError.failed(failure) }
        guard let response else { throw QuotaParseError.invalidResponse }
        return response
    }
}

enum QuotaFetcher {
    static func fetch(_ provider: LLMProvider) throws -> QuotaSnapshot {
        switch provider {
        case .codex:
            let windows = try QuotaParser.codex(CodexRPC.readRateLimits())
            return QuotaSnapshot(provider: provider, windows: windows, capturedAt: Date())
        case .claude:
            guard let snapshot = QuotaFiles.read(at: QuotaFiles.claudeFile(), provider: .claude) else {
                throw QuotaFetchError.notConfigured(
                    "Configura la status line di Claude per ricevere le quote"
                )
            }
            return snapshot
        case .antigravity:
            guard let executable = ExecutableLocator.find("agy", override: "LLMPULSE_AGY_PATH") else {
                throw QuotaFetchError.commandMissing("Antigravity CLI (agy)")
            }
            // Agy supports /usage without a model turn. Do NOT call a generative prompt.
            // Suppress CLI auto-updates and best-effort browser-login attempts.
            let bytes = try QuotaSubprocess.run(
                executable: executable,
                arguments: ["-p", "/usage", "--output-format", "json"],
                timeout: 30,
                environment: [
                    "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
                    "BROWSER": "/usr/bin/false",
                    "CI": "true"
                ]
            )
            return QuotaSnapshot(provider: provider, windows: try QuotaParser.antigravity(bytes),
                                 capturedAt: Date())
        }
    }
}

enum ClaudeIngest {
    // Invoked directly by Claude Code statusLine. No network, no auth access,
    // no transcript persistence. If no rate limits are present, keep the last
    // good snapshot rather than replacing it with 0%.
    static func ingest(stdin: FileHandle = .standardInput, output: Bool = true) -> Int32 {
        let input = stdin.readData(ofLength: 1024 * 1024 + 1)
        guard input.count <= 1024 * 1024,
              let windows = try? QuotaParser.claude(input) else {
            if output { print("Claude · quota non disponibile") }
            return 0  // A missing rate-limit window is not a statusline failure.
        }
        let snapshot = QuotaSnapshot(provider: .claude, windows: windows, capturedAt: Date())
        do {
            try QuotaFiles.write(snapshot, at: QuotaFiles.claudeFile())
        } catch {
            if output { print("Claude · errore lettura quote") }
            return 1
        }
        if output {
            let compact = windows.prefix(2).map { window in
                "\(window.name) \(Int(window.remainingPercent.rounded()))% rimasto"
            }.joined(separator: "  ·  ")
            print("Claude · " + compact)
        }
        return 0
    }
}
