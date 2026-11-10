import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// RunnerPulse is deliberately a single-file macOS menu-bar app. The parsing and
// aggregation code is Foundation-only, so it can be tested on non-macOS CI.

struct WorkflowRun: Decodable {
    let id: Int64
    let name: String?
    let display_title: String?
    let head_branch: String?
    let html_url: String?
    let status: String
    let conclusion: String?
    let created_at: String?
    let updated_at: String?
}
struct WorkflowRunsResponse: Decodable {
    let total_count: Int
    let workflow_runs: [WorkflowRun]
}
struct WorkflowStep: Decodable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int?
}
struct WorkflowJob: Decodable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let runner_id: Int64?
    let runner_name: String?
    let labels: [String]?
    let html_url: String?
    let started_at: String?
    let steps: [WorkflowStep]?
}
struct WorkflowJobsResponse: Decodable {
    let total_count: Int
    let jobs: [WorkflowJob]
}
struct RunnerLabel: Decodable { let name: String }
struct GitHubRunner: Decodable {
    let id: Int64
    let name: String
    let os: String?
    let status: String
    let busy: Bool
    let labels: [RunnerLabel]?
}
struct RunnersResponse: Decodable {
    let total_count: Int
    let runners: [GitHubRunner]
}

enum RunnerPulseCore {
    static func isSelfHosted(_ job: WorkflowJob, knownRunnerIDs: Set<Int64>) -> Bool {
        if let id = job.runner_id, knownRunnerIDs.contains(id) { return true }
        return job.labels?.contains(where: { $0.lowercased() == "self-hosted" }) == true
    }

    static func currentStep(_ job: WorkflowJob) -> String? {
        job.steps?.first(where: { $0.status == "in_progress" })?.name
    }

    static func stepCount(_ job: WorkflowJob) -> String? {
        guard let steps = job.steps, !steps.isEmpty else { return nil }
        let done = steps.filter { $0.status == "completed" }.count
        return "\(done)/\(steps.count) steps"
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: iso) { return value }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }

    static func duration(_ since: String?, now: Date = Date()) -> String {
        guard let start = date(since) else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func isLongRunning(_ since: String?, now: Date = Date(), limitMinutes: Int = 90) -> Bool {
        guard let date = date(since) else { return false }
        return now.timeIntervalSince(date) > Double(limitMinutes * 60)
    }

    static func validRepositories(_ input: String) -> [String] {
        let parts = input.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
        var seen = Set<String>()
        return parts.map(String.init).filter {
            let split = $0.split(separator: "/", omittingEmptySubsequences: false)
            guard split.count == 2 else { return false }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard split.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: allowed.inverted) == nil }) else { return false }
            return seen.insert($0.lowercased()).inserted
        }
    }

    static func validOrganizations(_ input: String) -> [String] {
        var seen = Set<String>()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return input.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).map(String.init).filter {
            !$0.isEmpty && $0.rangeOfCharacter(from: allowed.inverted) == nil &&
                seen.insert($0.lowercased()).inserted
        }
    }
}

struct ObservedJob: Identifiable {
    let repository: String
    let run: WorkflowRun
    let job: WorkflowJob?
    var id: String { "\(repository)/\(run.id)/\(job?.id ?? -1)" }
    var name: String { job?.name ?? run.name ?? "Workflow in attesa" }
    var runnerName: String? { job?.runner_name }
    var branch: String { run.head_branch ?? "—" }
    var started: String? { job?.started_at ?? run.created_at }
    var url: String? { job?.html_url ?? run.html_url }
    var step: String? { job.flatMap(RunnerPulseCore.currentStep) }
    var progress: String? { job.flatMap(RunnerPulseCore.stepCount) }
    var isLongRunning: Bool { RunnerPulseCore.isLongRunning(started) }
}

struct DisplayRunner: Identifiable {
    let id: String
    let name: String
    let status: String
    let busy: Bool
    let os: String?
    let job: ObservedJob?
    let observedOnly: Bool
}

struct RecentRun: Identifiable {
    let repository: String
    let run: WorkflowRun
    var id: String { "\(repository)/\(run.id)" }
}

struct RunnerPulseSnapshot {
    var runners: [DisplayRunner] = []
    var running: [ObservedJob] = []
    var queued: [ObservedJob] = []
    var failures: [RecentRun] = []
    var errors: [String] = []
    var warnings: [String] = []
    var lastUpdated: Date?
    var truncated = false

    var busyCount: Int { runners.filter { $0.busy }.count }
    var offlineCount: Int { runners.filter { $0.status == "offline" }.count }
    var longCount: Int { running.filter { $0.isLongRunning }.count }
}

// MARK: - Local foreground-runner telemetry (no GitHub credentials)

struct RunnerPulseLocalJob: Decodable {
    let name: String?
    let repository: String?
    let sha: String?
    let workflow: String?
    let event_name: String?
    // Optional v1 additions: old monitor snapshots remain readable.
    let execution_repository: String?
    let execution_sha: String?
    let trigger_mode: String?
    let attribution_status: String?
    let run_url: String?
    let started_at: Double
    let current_step: String?
    let steps: [String]?

    var originTitle: String {
        if attribution_status == "unresolved" { return "Origine non verificata" }
        return repository ?? "Repository in identificazione…"
    }
    var triggerTitle: String {
        switch trigger_mode {
        case "source_dispatch": return "Dal progetto"
        case "central_request": return "Richiesta centrale"
        case "native_workflow": return "Workflow diretto"
        default: return "Avvio non identificato"
        }
    }
    var sourceCommitURL: String? {
        guard attribution_status != "unresolved",
              let repo = repository, let sha = sha,
              repo.split(separator: "/").count == 2, sha.count == 40,
              sha.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "https://github.com/\(repo)/commit/\(sha)"
    }
}

struct RunnerPulseLocalEvent: Decodable, Identifiable {
    let time: Double
    let kind: String
    let name: String?
    let repository: String?
    let result: String?
    let duration_seconds: Double?
    let step: String?
    let execution_repository: String?
    let trigger_mode: String?
    let run_url: String?
    var id: String { "\(time)-\(kind)-\(name ?? "")-\(step ?? "")" }
}

struct RunnerPulseResources: Decodable {
    let cpu_percent: Double
    let ram_bytes: Int64
    let system_ram_bytes: Int64
    let process_count: Int
    let sampled_at: Double

    func isValid(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - sampled_at
        return age >= -5 && age <= 9 &&
            cpu_percent.isFinite && cpu_percent >= 0 && cpu_percent <= 100 &&
            ram_bytes >= 0 && system_ram_bytes > 0 && process_count > 0
    }
    var ramGB: Double { Double(ram_bytes) / 1_073_741_824 }
    var cpuFraction: Double { min(1, cpu_percent / 100) }
    var ramFraction: Double { min(1, Double(ram_bytes) / Double(system_ram_bytes)) }
}

struct RunnerPulseLocalSnapshot: Decodable, Identifiable {
    let schema_version: Int
    let runner_id: Int
    let session_id: String
    let pid: Int
    let updated_at: Double
    let status: String
    let job: RunnerPulseLocalJob?
    let resources: RunnerPulseResources?
    let recent_events: [RunnerPulseLocalEvent]

    var id: Int { runner_id }

    func isFresh(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - updated_at
        return schema_version == 1 && age >= -5 && age <= 6
    }
    var isRunning: Bool { isFresh() && status == "running" && job != nil }
    var isIdle: Bool { isFresh() && status == "idle" }
}

enum RunnerPulseLocalReader {
    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RunnerPulse/runners", isDirectory: true)
    }

    static func load(from directory: URL = defaultDirectory()) -> [RunnerPulseLocalSnapshot] {
        let decoder = JSONDecoder()
        return (1...4).compactMap { id in
            let file = directory.appendingPathComponent("runner-\(id).json")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let bytes = attrs[.size] as? NSNumber, bytes.intValue <= 128 * 1024,
                  let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(RunnerPulseLocalSnapshot.self, from: data),
                  snapshot.runner_id == id && snapshot.schema_version == 1 else { return nil }
            return snapshot
        }
    }
}

// Never treat previously written JSON as proof of a live telemetry session.
enum RunnerPulseLocalPolicy {
    static func hasFreshTelemetry(_ snapshots: [RunnerPulseLocalSnapshot],
                                  at now: Date = Date()) -> Bool {
        snapshots.contains { $0.isFresh(now: now) }
    }

    static func shouldRefreshRemote(previousFresh: Bool, currentFresh: Bool,
                                    remoteConfigured: Bool) -> Bool {
        remoteConfigured && previousFresh && !currentFresh
    }

    // A fresh stopped/starting runner is not idle, and an absent or expired
    // snapshot must never be presented as an available runner.
    static func overview(_ snapshots: [RunnerPulseLocalSnapshot],
                         at now: Date = Date()) -> (running: Int, idle: Int, other: Int) {
        var latest: [Int: RunnerPulseLocalSnapshot] = [:]
        for item in snapshots where (1...4).contains(item.runner_id) && item.isFresh(now: now) {
            if let previous = latest[item.runner_id], previous.updated_at > item.updated_at {
                continue
            }
            latest[item.runner_id] = item
        }
        let running = latest.values.filter { $0.status == "running" }.count
        let idle = latest.values.filter { $0.status == "idle" }.count
        return (running, idle, 4 - running - idle)
    }
}

enum RunnerPulseDiagnostics {
    static func observerErrorTail(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let url = home.appendingPathComponent("Library/Logs/RunnerPulse/observer.err.log")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return "Nessun errore registrato in observer.err.log (o log non ancora creato)."
        }
        // Strictly bounded, local-only diagnostics. Do not show raw worker logs,
        // since command output might contain credentials or business data.
        let tail = String(decoding: data.suffix(16 * 1024), as: UTF8.self)
        return tail.replacingOccurrences(
            of: "(?i)(github_pat_|ghp_|gho_|ghs_)[A-Za-z0-9_]+",
            with: "[TOKEN REDATTO]", options: .regularExpression
        ).split(separator: "\n").suffix(12).joined(separator: "\n")
    }

    static func eventSummary(_ snapshots: [RunnerPulseLocalSnapshot],
                             now: Date = Date()) -> [String] {
        snapshots.flatMap { snap in
            snap.recent_events.map { event -> (Double, String) in
                let age = Int(max(0, now.timeIntervalSince1970 - event.time))
                let origin = event.repository.map { " · \($0)" } ?? ""
                let description = event.step ?? event.name ?? event.kind
                return (event.time, "runner-\(snap.runner_id) · \(description)\(origin) · \(age)s fa")
            }
        }.sorted { $0.0 > $1.0 }.prefix(15).map { $0.1 }
    }
}


enum RunnerAPIError: LocalizedError {
    case invalidResponse(Int)
    case api(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse(let status): return "Risposta HTTP \(status)"
        case .api(let code, let message): return "HTTP \(code): \(message)"
        }
    }
}

struct RunnerPulseAPI {
    let token: String
    private let decoder = JSONDecoder()

    private func fetch<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw RunnerAPIError.invalidResponse(0)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        request.addValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.addValue("RunnerPulse/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RunnerAPIError.invalidResponse(0) }
        guard http.statusCode == 200 else {
            // Never include arbitrary response bodies: GitHub error text could contain sensitive data.
            throw RunnerAPIError.api(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return try decoder.decode(T.self, from: data)
    }

    func load(repositories: [String], organizations: [String]) async -> RunnerPulseSnapshot {
        var snapshot = RunnerPulseSnapshot()
        var runnersByID: [Int64: GitHubRunner] = [:]
        var observedJobs: [ObservedJob] = []
        var pendingRuns: [RecentRun] = []
        var finished: [RecentRun] = []

        // Runner listing is optional: Actions:read alone is enough for the job view.
        for org in organizations {
            do {
                let response: RunnersResponse = try await fetch("/orgs/\(org)/actions/runners?per_page=100")
                for runner in response.runners { runnersByID[runner.id] = runner }
                if response.total_count > response.runners.count { snapshot.truncated = true }
            } catch {
                snapshot.warnings.append("\(org): runner dell'organizzazione non accessibili (\(error.localizedDescription))")
            }
        }

        for repository in repositories {
            let root = "/repos/\(repository)/actions"
            do {
                let active: WorkflowRunsResponse = try await fetch("\(root)/runs?status=in_progress&per_page=100")
                let pending: WorkflowRunsResponse = try await fetch("\(root)/runs?status=queued&per_page=100")
                let latest: WorkflowRunsResponse = try await fetch("\(root)/runs?per_page=20")
                if active.total_count > active.workflow_runs.count || pending.total_count > pending.workflow_runs.count {
                    snapshot.truncated = true
                }
                let unique = Dictionary((active.workflow_runs + pending.workflow_runs).map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
                for run in unique.values {
                    // In large repositories avoid an unbounded number of requests per refresh.
                    pendingRuns.append(RecentRun(repository: repository, run: run))
                }
                finished += latest.workflow_runs.filter {
                    $0.status == "completed" && ["failure", "timed_out", "action_required"].contains($0.conclusion ?? "")
                }.map { RecentRun(repository: repository, run: $0) }

                // Repo-scoped runner API requires Administration:read. Never misreport
                // unavailable runner data as 0 runners.
                do {
                    let response: RunnersResponse = try await fetch("\(root)/runners?per_page=100")
                    for runner in response.runners { runnersByID[runner.id] = runner }
                    if response.total_count > response.runners.count { snapshot.truncated = true }
                } catch {
                    snapshot.warnings.append("\(repository): elenco runner non accessibile (richiede Administration:read)")
                }
            } catch {
                snapshot.errors.append("\(repository): \(error.localizedDescription)")
            }
        }

        // Jobs are fetched for each active workflow; sorting ensures the most
        // recently updated workflows are chosen if the bounded request budget is reached.
        let sortedRuns = pendingRuns.sorted {
            (RunnerPulseCore.date($0.run.updated_at) ?? .distantPast) >
                (RunnerPulseCore.date($1.run.updated_at) ?? .distantPast)
        }
        if sortedRuns.count > 35 { snapshot.truncated = true }
        let knownIDs = Set(runnersByID.keys)
        for item in sortedRuns.prefix(35) {
            do {
                let response: WorkflowJobsResponse = try await fetch(
                    "/repos/\(item.repository)/actions/runs/\(item.run.id)/jobs?per_page=100"
                )
                if response.total_count > response.jobs.count { snapshot.truncated = true }
                let matching = response.jobs.filter {
                    RunnerPulseCore.isSelfHosted($0, knownRunnerIDs: knownIDs)
                        && ["queued", "waiting", "pending", "in_progress"].contains($0.status)
                }
                if matching.isEmpty && item.run.status == "queued" {
                    // Workflow-level queue is shown as unclassified, not asserted self-hosted.
                    snapshot.queued.append(ObservedJob(repository: item.repository, run: item.run, job: nil))
                }
                for job in matching {
                    let observed = ObservedJob(repository: item.repository, run: item.run, job: job)
                    if job.status == "in_progress" { observedJobs.append(observed) }
                    else { snapshot.queued.append(observed) }
                }
            } catch {
                snapshot.warnings.append("\(item.repository) #\(item.run.id): job non accessibili")
            }
        }
        snapshot.running = observedJobs.sorted { $0.repository < $1.repository }
        let byRunnerID = Dictionary(grouping: snapshot.running.compactMap { observed -> (Int64, ObservedJob)? in
            guard let id = observed.job?.runner_id else { return nil }
            return (id, observed)
        }, by: { $0.0 })
        var cards = runnersByID.values.map { runner -> DisplayRunner in
            let job = byRunnerID[runner.id]?.first?.1
            return DisplayRunner(id: "runner-\(runner.id)", name: runner.name,
                                 status: runner.status, busy: runner.busy,
                                 os: runner.os, job: job, observedOnly: false)
        }
        let knownRunnerIDs = Set(runnersByID.keys)
        for job in snapshot.running {
            if let id = job.job?.runner_id, knownRunnerIDs.contains(id) { continue }
            guard let name = job.runnerName, !name.isEmpty else { continue }
            cards.append(DisplayRunner(id: "job-\(job.id)", name: name, status: "observed",
                                       busy: true, os: nil, job: job, observedOnly: true))
        }
        snapshot.runners = cards.sorted {
            if $0.busy != $1.busy { return $0.busy && !$1.busy }
            if $0.status == "offline" && $1.status != "offline" { return false }
            if $1.status == "offline" && $0.status != "offline" { return true }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        snapshot.queued.sort { $0.repository < $1.repository }
        snapshot.failures = Array(finished.sorted {
            (RunnerPulseCore.date($0.run.updated_at) ?? .distantPast) >
                (RunnerPulseCore.date($1.run.updated_at) ?? .distantPast)
        }.prefix(5))
        snapshot.lastUpdated = Date()
        return snapshot
    }
}

#if canImport(AppKit) && !RUNNERPULSE_TEST
import AppKit
import SwiftUI
import Security
import Combine

enum RunnerPulseKeychain {
    private static let service = "com.daniele.runnerpulse"
    private static let account = "github-token"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if token.isEmpty {
            return SecItemDelete(query as CFDictionary) == errSecSuccess
                || read() == nil
        }
        let attrs: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let result = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
        if result == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

// MARK: - Optional launchd-managed local session
// Never starts a runner when any live foreground telemetry exists, never uses
// --force, and never stops/kills other runner processes or launchd services.
// The existing Python preflight also refuses busy/duplicate runners.
enum RunnerPulseBackgroundControl {
    static let label = "com.daniele.runnerpulse.background-runners"
    static let serviceName = "runnerpulse-background-runners.plist"

    static func scriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Projects/local-runner-infra/scripts/interactive_runners.py")
    }

    static func plistURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(serviceName)")
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "")
    }

    private static func pythonExecutable() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func alreadyRunning(_ domain: String) -> Bool {
        guard let check = try? runLaunchctl(["print", "\(domain)/\(label)"]),
              check.0 == 0 else { return false }
        // launchctl reports "pid = ..." for an active service instance.
        return check.1.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ")
        }
    }

    static func start() throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let script = scriptURL(home: home)
        guard fm.fileExists(atPath: script.path),
              fm.fileExists(atPath: script.deletingLastPathComponent()
                .appendingPathComponent("runner_monitor/status.py").path) else {
            throw NSError(domain: "RunnerPulse", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Monitor aggiornato non trovato in ~/Projects/local-runner-infra. Aggiorna quel repository."])
        }
        guard let python = pythonExecutable() else {
            throw NSError(domain: "RunnerPulse", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Python 3 non trovato."])
        }
        for id in 1...4 {
            let runner = home.appendingPathComponent("actions-runners/runner-\(id)/run.sh")
            guard fm.fileExists(atPath: runner.path) else {
                throw NSError(domain: "RunnerPulse", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "runner-\(id) non configurato in ~/actions-runners."])
            }
        }
        let domain = "gui/\(getuid())"
        if alreadyRunning(domain) {
            return "Sessione in background già attiva."
        }
        if RunnerPulseLocalReader.load().contains(where: { $0.isFresh() &&
            ["starting", "running", "idle"].contains($0.status) }) {
            throw NSError(domain: "RunnerPulse", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "I runner risultano già gestiti da una sessione attiva. Non verrà creata una seconda istanza."])
        }
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/RunnerPulse", isDirectory: true)
        try fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let destination = plistURL(home: home)
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [python, script.path, "--no-color"],
            "WorkingDirectory": script.deletingLastPathComponent().deletingLastPathComponent().path,
            "EnvironmentVariables": [
                "HOME": home.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "PYTHONUNBUFFERED": "1"
            ],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logs.appendingPathComponent("background-runners.log").path,
            "StandardErrorPath": logs.appendingPathComponent("background-runners.err.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: contents,
                                                      format: .xml, options: 0)
        try data.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let registered = (try? runLaunchctl(["print", "\(domain)/\(label)"]).0) == 0
        if !registered {
            let result = try runLaunchctl(["bootstrap", domain, destination.path])
            guard result.0 == 0 else {
                throw NSError(domain: "RunnerPulse", code: 5,
                              userInfo: [NSLocalizedDescriptionKey:
                                "launchd bootstrap: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
        }
        // One last no-duplicate check after service registration. Never use -k.
        if alreadyRunning(domain) { return "Sessione in background già attiva." }
        if RunnerPulseLocalReader.load().contains(where: { $0.isFresh() &&
            ["starting", "running", "idle"].contains($0.status) }) {
            throw NSError(domain: "RunnerPulse", code: 6,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Un'altra sessione runner è partita nel frattempo. Avvio annullato."])
        }
        let result = try runLaunchctl(["kickstart", "\(domain)/\(label)"])
        guard result.0 == 0 else {
            throw NSError(domain: "RunnerPulse", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                            "launchd kickstart: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return "Avvio richiesto. La connessione e i controlli preflight possono richiedere qualche secondo."
    }

    // Install/recover only the read-only observer. Actions runners are not touched.
    static func repairObserver() throws -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let label = "com.daniele.runnerpulse.observer"
        let service = "gui/\(getuid())/\(label)"
        if let check = try? runLaunchctl(["print", service]), check.0 == 0 {
            let result = try runLaunchctl(["kickstart", "-k", service])
            guard result.0 == 0 else {
                throw NSError(domain: "RunnerPulse", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Riavvio observer: \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))"
                ])
            }
            return "Observer riavviato; runner GitHub Actions invariati."
        }

        let candidates = ["Projects/local-runner-infra", "Personal/local-runner-infra"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        guard let infra = candidates.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("scripts/runnerpulse_observer.py").path) &&
            fm.fileExists(atPath: $0.appendingPathComponent("scripts/runner_monitor/status.py").path)
        }) else {
            throw NSError(domain: "RunnerPulse", code: 8, userInfo: [
                NSLocalizedDescriptionKey:
                    "Sorgente observer non trovata in ~/Projects/local-runner-infra o ~/Personal/local-runner-infra. Aggiorna local-runner-infra prima di riprovare."
            ])
        }
        guard let python = pythonExecutable() else {
            throw NSError(domain: "RunnerPulse", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Python 3 non disponibile."
            ])
        }
        let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/RunnerPulse", isDirectory: true)
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let observer = infra.appendingPathComponent("scripts/runnerpulse_observer.py")
        let plist = agents.appendingPathComponent("\(label).plist")
        let contents: [String: Any] = [
            "Label": label,
            "ProgramArguments": [python, observer.path, "--interval", "1"],
            "WorkingDirectory": infra.path,
            "EnvironmentVariables": [
                "HOME": home.path,
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "PYTHONUNBUFFERED": "1"
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 20,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logs.appendingPathComponent("observer.log").path,
            "StandardErrorPath": logs.appendingPathComponent("observer.err.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: contents,
                                                      format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plist.path)
        let result = try runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
        guard result.0 == 0 else {
            throw NSError(domain: "RunnerPulse", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Installazione observer (launchd): \(result.1.trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
        }
        return "Observer installato e avviato. I runner CI non sono stati riavviati."
    }

    static func logURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RunnerPulse/background-runners.err.log")
    }
}

final class RunnerPulseState: ObservableObject {
    @Published var snapshot = RunnerPulseSnapshot()
    @Published var refreshing = false
    @Published var showSettings = false
    @Published var settingsError: String?
    @Published var repositoriesText: String
    @Published var organizationsText: String
    // Transient token input lives in the existing ObservableObject, not @State.
    // The current macOS CLT SDK requires a SwiftUIMacros plugin for @State
    // that is only bundled with full Xcode. Never persist this draft.
    @Published var pendingToken = ""
    @Published var localSnapshots: [RunnerPulseLocalSnapshot] = []
    @Published var launchingRunners = false
    @Published var runnerControlMessage: String?
    @Published var restartingObserver = false
    @Published var observerMessage: String?
    @Published var showDiagnostics = false
    @Published var showAllActivity = false
    @Published var observerErrorLog = ""
    private var localTimer: Timer?
    private var lastLocalPollWasFresh = false
    private var token: String?
    private var lastRequest: Date?
    private var generation = 0
    private var timer: Timer?

    init() {
        repositoriesText = UserDefaults.standard.string(forKey: "runnerpulse.repositories") ?? ""
        organizationsText = UserDefaults.standard.string(forKey: "runnerpulse.organizations") ?? ""
        token = RunnerPulseKeychain.read()
        // Local dashboard is the default: never force a GitHub auth dialog on launch.
        showSettings = false
    }

    var configured: Bool {
        token != nil && !RunnerPulseCore.validRepositories(repositoriesText).isEmpty
    }

    func saveSettings(token newToken: String) {
        let repos = RunnerPulseCore.validRepositories(repositoriesText)
        guard !repos.isEmpty else {
            settingsError = "Aggiungi almeno un repository nel formato owner/repo."
            return
        }
        if !newToken.isEmpty {
            guard RunnerPulseKeychain.save(newToken.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                settingsError = "Impossibile salvare il token nel Portachiavi."
                return
            }
            token = RunnerPulseKeychain.read()
        }
        guard token != nil else {
            settingsError = "Inserisci un token GitHub con Actions:read."
            return
        }
        UserDefaults.standard.set(repos.joined(separator: "\n"), forKey: "runnerpulse.repositories")
        let orgs = RunnerPulseCore.validOrganizations(organizationsText)
        UserDefaults.standard.set(orgs.joined(separator: "\n"), forKey: "runnerpulse.organizations")
        repositoriesText = repos.joined(separator: "\n")
        organizationsText = orgs.joined(separator: "\n")
        pendingToken = ""
        settingsError = nil
        showSettings = false
        refresh(force: true)
    }

    func removeToken() {
        guard RunnerPulseKeychain.save("") else {
            settingsError = "Impossibile eliminare il token dal Portachiavi."
            return
        }
        token = nil
        pendingToken = ""
        snapshot = RunnerPulseSnapshot()
        showSettings = true
    }

    var hasLocalTelemetry: Bool {
        RunnerPulseLocalPolicy.hasFreshTelemetry(localSnapshots)
    }
    var hasStaleLocalTelemetry: Bool {
        !localSnapshots.isEmpty && !hasLocalTelemetry
    }
    var latestLocalHeartbeatAge: TimeInterval? {
        guard let newest = localSnapshots.map(\.updated_at).max() else { return nil }
        return max(0, Date().timeIntervalSince1970 - newest)
    }
    var hasLiveLocalSession: Bool {
        localSnapshots.contains(where: { $0.isFresh() && ["starting", "running", "idle"].contains($0.status) })
    }

    func launchRunnersInBackground() {
        guard !launchingRunners, !hasLiveLocalSession else { return }
        launchingRunners = true
        runnerControlMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String
            do {
                message = try RunnerPulseBackgroundControl.start()
            } catch {
                message = "Avvio non riuscito: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self?.launchingRunners = false
                self?.runnerControlMessage = message
                self?.pollLocal()
            }
        }
    }

    func restartObserver() {
        guard !restartingObserver else { return }
        restartingObserver = true
        observerMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String
            do {
                message = try RunnerPulseBackgroundControl.repairObserver()
            } catch {
                message = "Observer non riavviato: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self?.restartingObserver = false
                self?.observerMessage = message
                self?.pollLocal()
            }
        }
    }

    func openDiagnostics() {
        observerErrorLog = RunnerPulseDiagnostics.observerErrorTail()
        showDiagnostics = true
    }

    func reloadDiagnostics() {
        observerErrorLog = RunnerPulseDiagnostics.observerErrorTail()
        pollLocal()
    }

    func openBackgroundLog() {
        let url = RunnerPulseBackgroundControl.logURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    func pollLocal() {
        let current = RunnerPulseLocalReader.load()
        let currentFresh = RunnerPulseLocalPolicy.hasFreshTelemetry(current)
        let fallback = RunnerPulseLocalPolicy.shouldRefreshRemote(
            previousFresh: lastLocalPollWasFresh,
            currentFresh: currentFresh,
            remoteConfigured: configured
        )
        lastLocalPollWasFresh = currentFresh
        localSnapshots = current
        // Refresh immediately when the last live local heartbeat disappears,
        // rather than waiting for the next slow GitHub polling interval.
        if fallback { refresh(force: true) }
    }

    func start() {
        pollLocal()
        // .common keeps polling alive while the status-bar popover is being used
        // and AppKit switches away from the default run-loop mode.
        let local = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollLocal()
        }
        localTimer = local
        RunLoop.main.add(local, forMode: .common)
        refresh(force: true) // Optional GitHub view remains available when configured.
    }

    func refresh(force: Bool = false) {
        guard configured, !refreshing, let token else { return }
        if !force, let lastRequest, Date().timeIntervalSince(lastRequest) < 15 { return }
        timer?.invalidate()
        lastRequest = Date()
        refreshing = true
        generation += 1
        let current = generation
        let repos = RunnerPulseCore.validRepositories(repositoriesText)
        let orgs = RunnerPulseCore.validOrganizations(organizationsText)
        Task {
            let result = await RunnerPulseAPI(token: token).load(repositories: repos, organizations: orgs)
            guard generation == current else { return }
            snapshot = result
            refreshing = false
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        // Idle polling is intentionally slower to minimize API usage.
        let seconds: TimeInterval = snapshot.running.isEmpty && snapshot.queued.isEmpty ? 120 : 45
        let next = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

private func safeGitHubURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), url.scheme == "https", url.host == "github.com" else {
        return nil
    }
    return url
}
private func openGitHub(_ raw: String?) {
    guard let url = safeGitHubURL(raw) else { return }
    NSWorkspace.shared.open(url)
}

private struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

private struct JobSubline: View {
    let job: ObservedJob
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.repository).font(.system(size: 11, weight: .semibold))
            Text(job.name).font(.system(size: 11)).lineLimit(1)
            HStack(spacing: 7) {
                Text(job.branch)
                if let step = job.step { Text("· \(step)").lineLimit(1) }
                if let progress = job.progress { Text("· \(progress)") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct RunnerRow: View {
    let runner: DisplayRunner
    var body: some View {
        Button {
            openGitHub(runner.job?.url)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(runner.status == "offline" ? Color.red : runner.busy ? Color.green : Color.gray)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(runner.name).font(.system(size: 12, weight: .semibold))
                        if runner.observedOnly {
                            Text("job osservato").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(runner.status == "offline" ? "Offline" : runner.busy ? "Busy" : "Idle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(runner.status == "offline" ? Color.red : Color.secondary)
                    }
                    if let job = runner.job {
                        JobSubline(job: job)
                        HStack {
                            if job.isLongRunning {
                                Label("Lungo", systemImage: "exclamationmark.clock")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(RunnerPulseCore.duration(job.started))
                                .monospacedDigit()
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(runner.busy ? "Occupato da un job non visibile nei repository monitorati"
                             : runner.status == "offline" ? "Runner disconnesso" : "Disponibile")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(runner.job.flatMap { safeGitHubURL($0.url) } == nil)
    }
}

private struct SimpleJobRow: View {
    let item: ObservedJob
    var body: some View {
        Button { openGitHub(item.url) } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.repository).font(.system(size: 11, weight: .medium))
                    Text(item.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if item.job == nil {
                        Text("Runner non ancora assegnato · tipo non verificato")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(RunnerPulseCore.duration(item.started))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }.buttonStyle(.plain)
    }
}

private struct RunnerPulseSettings: View {
    @ObservedObject var state: RunnerPulseState
    // Bind the SecureField to RunnerPulseState's @Published draft.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Impostazioni GitHub").font(.headline)
                Spacer()
                if state.configured {
                    Button("Chiudi") {
                        state.pendingToken = ""
                        state.showSettings = false
                    }
                }
            }
            Text("Repository da monitorare (uno per riga, owner/repo)")
                .font(.system(size: 11, weight: .medium))
            TextEditor(text: $state.repositoriesText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("Organizzazioni da monitorare (opzionale, una per riga)")
                .font(.system(size: 11, weight: .medium))
            TextField("nome-organizzazione", text: $state.organizationsText)
                .textFieldStyle(.roundedBorder)
            Text("GitHub token · lasciando vuoto mantieni quello esistente")
                .font(.system(size: 11, weight: .medium))
            SecureField("github_pat_…", text: $state.pendingToken)
                .textFieldStyle(.roundedBorder)
            Text("Token solo nel Portachiavi macOS. Permessi: Actions:read; Administration:read per runner repo; Self-hosted runners:read per org.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let error = state.settingsError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                if state.configured {
                    Button("Rimuovi token", role: .destructive) { state.removeToken() }
                }
                Spacer()
                Button("Salva e aggiorna") {
                    state.saveSettings(token: state.pendingToken)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 410)
    }
}

// MARK: - Local runner activity (read-only)

// Only two small measurements; no graph, sensor history or extra window.
// MARK: - RunnerPulse menubar dashboard

private enum RunnerPulseStyle {
    static let running = Color.green
    static let warning = Color.orange
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color.primary.opacity(0.075)
}

private struct RunnerResourceBars: View {
    let metrics: RunnerPulseResources?

    private func meter(_ label: String, value: String, fraction: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).foregroundStyle(.primary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let active = metrics?.isValid() == true ? metrics : nil
        HStack(spacing: 18) {
            meter("CPU totale", value: active.map { String(format: "%.0f%%", $0.cpu_percent) } ?? "—",
                  fraction: active?.cpuFraction ?? 0,
                  color: (active?.cpu_percent ?? 0) >= 75 ? .orange : .cyan)
            meter("RAM RSS", value: active.map { String(format: "%.1f GB", $0.ramGB) } ?? "—",
                  fraction: active?.ramFraction ?? 0,
                  color: (active?.ramFraction ?? 0) >= 0.75 ? .orange : .purple)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.top, 5)
        .help("Uso stimato di Runner.Worker e figli. CPU: percentuale della capacità totale del Mac. RAM: RSS, con possibili pagine condivise.")
    }
}

private struct RunnerSummaryTile: View {
    let title: String
    let count: Int
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RunnerPulseStyle.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(RunnerPulseStyle.stroke))
        .accessibilityElement(children: .combine)
    }
}

private struct LocalRunnerCard: View {
    let id: Int
    let snapshot: RunnerPulseLocalSnapshot?

    private var fresh: Bool { snapshot?.isFresh() == true }
    private var status: String { fresh ? snapshot?.status ?? "unknown" : "unobserved" }
    private var tint: Color {
        switch status {
        case "running": return RunnerPulseStyle.running
        case "idle": return .secondary
        case "starting": return .cyan
        default: return RunnerPulseStyle.warning
        }
    }
    private var statusTitle: String {
        switch status {
        case "running": return "In esecuzione"
        case "idle": return "Disponibile"
        case "starting": return "In avvio"
        case "stopped": return "Fermato"
        case "unobserved": return "Non osservato"
        default: return "Stato sconosciuto"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: status == "running" ? 8 : 2) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("runner-\(id)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer(minLength: 6)
                Text(statusTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                if status == "running", let started = snapshot?.job?.started_at {
                    Text(RunnerPulseCore.duration(ISO8601DateFormatter()
                        .string(from: Date(timeIntervalSince1970: started))))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if status == "running" {
                if let job = snapshot?.job {
                    HStack(spacing: 7) {
                        Text(job.originTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(job.attribution_status == "unresolved"
                                ? RunnerPulseStyle.warning : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(job.originTitle)
                        Spacer(minLength: 0)
                        Text(job.triggerTitle)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.065), in: Capsule())
                            .lineLimit(1)
                    }
                    Text(job.name ?? "Job in esecuzione")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .help(job.name ?? "Job in esecuzione")
                    if let step = job.current_step, !step.isEmpty {
                        Label(step, systemImage: "arrow.turn.down.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help("Step corrente: \(step)")
                    } else {
                        Text("Step corrente non ancora disponibile")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if let executor = job.execution_repository,
                       executor != job.repository {
                        Text("Workflow eseguito da \(executor)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    RunnerResourceBars(metrics: snapshot?.resources)
                    if job.sourceCommitURL != nil || safeGitHubURL(job.run_url) != nil {
                        HStack(spacing: 15) {
                            if let url = job.run_url, safeGitHubURL(url) != nil {
                                Button {
                                    openGitHub(url)
                                } label: {
                                    Label("Log GitHub", systemImage: "arrow.up.right")
                                }
                            }
                            if let sha = job.sha, let url = job.sourceCommitURL {
                                Button("Commit \(String(sha.prefix(8)))") {
                                    openGitHub(url)
                                }
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    }
                } else {
                    Text("Runner occupato · dettagli del job in acquisizione")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if status == "unobserved" {
                Text("Nessun heartbeat recente · stato non verificato")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if status == "stopped" {
                Text("Runner fermato · non disponibile per nuovi job")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if status == "starting" {
                Text("Avvio del servizio in corso")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, status == "running" ? 12 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RunnerPulseStyle.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            status == "running" ? RunnerPulseStyle.running.opacity(0.25) : RunnerPulseStyle.stroke))
        .accessibilityElement(children: .contain)
    }
}

private struct LocalDashboard: View {
    let snapshots: [RunnerPulseLocalSnapshot]
    @ObservedObject var state: RunnerPulseState

    private var overview: (running: Int, idle: Int, other: Int) {
        RunnerPulseLocalPolicy.overview(snapshots)
    }
    private var live: [RunnerPulseLocalSnapshot] {
        snapshots.filter { $0.isFresh() }
    }
    private var events: [(Int, RunnerPulseLocalEvent)] {
        Array(live.flatMap { snap in
            snap.recent_events.map { (snap.runner_id, $0) }
        }.sorted { $0.1.time > $1.1.time }.prefix(12))
    }
    private func eventTitle(_ event: RunnerPulseLocalEvent) -> String {
        switch event.kind {
        case "job_started": return "Avvio · \(event.name ?? "job")"
        case "job_completed": return "\(event.name ?? "Job") · \(event.result ?? "completato")"
        case "step_started": return event.step ?? "Step avviato"
        case "runner_started": return "Runner avviato"
        case "runner_stopped": return "Runner terminato"
        default: return event.kind.replacingOccurrences(of: "_", with: " ")
        }
    }
    private func eventColor(_ event: RunnerPulseLocalEvent) -> Color {
        if event.kind == "job_completed" {
            return ["succeeded", "success"].contains(event.result?.lowercased() ?? "")
                ? .green : .red
        }
        return event.kind == "runner_stopped" ? .orange : .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(RunnerPulseStyle.running).frame(width: 6, height: 6)
                Text("Telemetria locale")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(live.count)/4 osservati")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 15)
            .padding(.top, 11)
            .padding(.bottom, 9)

            HStack(spacing: 7) {
                RunnerSummaryTile(title: "In esecuzione", count: overview.running,
                                  icon: "play.fill", tint: .green)
                RunnerSummaryTile(title: "Disponibili", count: overview.idle,
                                  icon: "checkmark.circle", tint: .secondary)
                RunnerSummaryTile(title: "Da verificare", count: overview.other,
                                  icon: "exclamationmark.circle",
                                  tint: overview.other > 0 ? .orange : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("RUNNER").tracking(0.8)
                        Spacer()
                        Text("Stato in tempo reale")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                    // Busy runners lead; idle cards remain short and unobserved
                    // runners stay visible instead of appearing falsely idle.
                    ForEach((1...4).sorted { a, b in
                        let aRunning = snapshots.first { $0.runner_id == a }?.isRunning == true
                        let bRunning = snapshots.first { $0.runner_id == b }?.isRunning == true
                        return aRunning == bRunning ? a < b : aRunning && !bRunning
                    }, id: \.self) { id in
                        LocalRunnerCard(id: id, snapshot: snapshots.first { $0.runner_id == id })
                    }

                    HStack {
                        Text("ATTIVITÀ RECENTI").tracking(0.8)
                        Spacer()
                        if events.count > 4 {
                            Button(state.showAllActivity ? "Mostra meno" : "Mostra tutti (\(events.count))") {
                                state.showAllActivity.toggle()
                            }
                            .font(.system(size: 10, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    if events.isEmpty {
                        Label("Nessun evento recente disponibile", systemImage: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    let displayed = state.showAllActivity ? events : Array(events.prefix(4))
                    ForEach(displayed.indices, id: \.self) { index in
                        let (id, event) = displayed[index]
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(eventColor(event))
                                .frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("runner-\(id) · \(eventTitle(event))")
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(2)
                                if let origin = event.repository {
                                    Text(origin)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else if event.trigger_mode == "central_request" {
                                    Text("Origine non verificata")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                }
                                if let link = event.run_url, safeGitHubURL(link) != nil {
                                    Button("Apri log GitHub") { openGitHub(link) }
                                        .font(.system(size: 10, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(Date(timeIntervalSince1970: event.time)
                                .formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        if index < displayed.count - 1 {
                            Divider().opacity(0.6)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct RunnerPulsePanel: View {
    @ObservedObject var state: RunnerPulseState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RunnerPulse").font(.system(size: 15, weight: .semibold))
                    Text("Self-hosted GitHub Actions").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if state.hasLocalTelemetry {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("LIVE").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.green)
                    .padding(.trailing, 3)
                }
                if state.refreshing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Button {
                    state.pollLocal()
                    state.refresh(force: true)
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Aggiorna stato locale e GitHub, se configurato")
                Button { state.openDiagnostics() } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.plain).help("Log e diagnostica")
                Button { state.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Impostazioni")
            }
            .padding(16)
            Divider()
            if !state.hasLocalTelemetry {
                VStack(alignment: .leading, spacing: 7) {
                    Label(state.hasStaleLocalTelemetry
                          ? "Telemetria locale scaduta"
                          : "Monitor locale non disponibile",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11, weight: .medium))
                    if let age = state.latestLocalHeartbeatAge, state.hasStaleLocalTelemetry {
                        Text("Ultimo heartbeat \(Int(age))s fa. Lo stato dei runner non è verificabile dai file locali; \(state.configured ? "visualizzo i dati GitHub." : "configura GitHub come alternativa.")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nessun heartbeat locale ricevuto. L'observer è indipendente dai runner CI.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button {
                            state.restartObserver()
                        } label: {
                            Label(state.restartingObserver ? "Ripristino observer…" : "Ripristina observer",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(state.restartingObserver)
                        .buttonStyle(.bordered)
                        Spacer()
                        if state.configured {
                            Button("Aggiorna GitHub") { state.refresh(force: true) }
                                .buttonStyle(.plain)
                        }
                    }
                    if let message = state.observerMessage {
                        Text(message)
                            .foregroundStyle(message.hasPrefix("Observer non riavviato") ? Color.red : Color.secondary)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                Divider()
            }
            // Stale telemetry means we cannot establish whether workers are
            // already busy. Never encourage starting another runner session.
            if state.localSnapshots.count == 4 &&
               state.localSnapshots.allSatisfy({ $0.isFresh() && $0.status == "stopped" }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Button {
                            state.launchRunnersInBackground()
                        } label: {
                            Label(state.launchingRunners ? "Avvio in corso…" : "Avvia runner in background",
                                  systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.launchingRunners)
                        Spacer()
                        Button("Log avvio") { state.openBackgroundLog() }
                            .font(.system(size: 10))
                    }
                    Text("Avvia solo se i quattro runner sono verificati come fermati. Non usa --force e non crea sessioni duplicate.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let message = state.runnerControlMessage {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(message.hasPrefix("Avvio non riuscito") ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                Divider()
            }
            if state.hasLocalTelemetry {
                LocalDashboard(snapshots: state.localSnapshots, state: state)
            } else if !state.configured {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Monitor locale", systemImage: "desktopcomputer").font(.headline)
                    Text("Nessuna telemetria locale ricevuta. Usa Ripristina observer: installa o riavvia soltanto il lettore passivo, senza toccare i worker CI.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("La dashboard leggerà automaticamente i runner senza richiedere un token GitHub.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Configura GitHub remoto (facoltativo)") { state.showSettings = true }
                }.padding(18)
                Spacer()
            } else {
                HStack(spacing: 13) {
                    Label("\(state.snapshot.running.count) job", systemImage: "play.circle.fill")
                        .foregroundStyle(.green)
                    Label("\(state.snapshot.queued.count) coda", systemImage: "clock")
                        .foregroundStyle(.orange)
                    if state.snapshot.offlineCount > 0 {
                        Label("\(state.snapshot.offlineCount) offline", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("WORKERS", count: state.snapshot.runners.count)
                        if state.snapshot.runners.isEmpty {
                            infoText(state.refreshing ? "Caricamento…" : "Nessun runner visibile. Controlla i permessi o aggiungi un repository con job self-hosted.")
                        }
                        ForEach(state.snapshot.runners) { runner in RunnerRow(runner: runner) }
                        // When runner inventory isn't accessible, queued/running jobs
                        // still appear independently so they don't get lost.
                        let unresolved = state.snapshot.running.filter { observed in
                            !state.snapshot.runners.contains(where: { $0.job?.id == observed.id })
                        }
                        if !unresolved.isEmpty {
                            sectionHeader("JOB SENZA RUNNER ASSEGNATO", count: unresolved.count)
                            ForEach(unresolved) { job in SimpleJobRow(item: job) }
                        }
                        sectionHeader("IN CODA", count: state.snapshot.queued.count)
                        if state.snapshot.queued.isEmpty { infoText("Nessun job self-hosted in attesa rilevato") }
                        ForEach(state.snapshot.queued) { job in SimpleJobRow(item: job) }
                        if !state.snapshot.failures.isEmpty {
                            sectionHeader("ULTIMI FALLIMENTI", count: state.snapshot.failures.count)
                            ForEach(state.snapshot.failures) { item in
                                Button {
                                    openGitHub(item.run.html_url)
                                } label: {
                                    HStack {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                        VStack(alignment: .leading) {
                                            Text(item.repository).font(.system(size: 11, weight: .medium))
                                            Text(item.run.name ?? "Workflow")
                                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(item.run.conclusion ?? "failed")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.padding(.vertical, 3)
                                }.buttonStyle(.plain)
                            }
                        }
                        ForEach(state.snapshot.errors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).font(.system(size: 10))
                        }
                        ForEach(state.snapshot.warnings, id: \.self) { message in
                            Label(message, systemImage: "info.circle")
                                .foregroundStyle(.secondary).font(.system(size: 10))
                        }
                        if state.snapshot.truncated {
                            infoText("Limite di paginazione / richieste raggiunto: alcuni job o runner potrebbero non essere mostrati.")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            HStack {
                if state.hasLocalTelemetry {
                    Text("Dati locali · aggiornamento ogni 1s")
                } else if let date = state.snapshot.lastUpdated {
                    Text("GitHub · \(date.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("In attesa di telemetria")
                }
                Spacer()
                Button("GitHub") {
                    openGitHub("https://github.com/actions")
                }
                Button("Esci") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(12)
        }
        .frame(width: 430, height: 555)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $state.showSettings) {
            RunnerPulseSettings(state: state)
        }
        .sheet(isPresented: $state.showDiagnostics) {
            RunnerPulseDiagnosticsView(state: state)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).tracking(0.7)
            Spacer()
            Text("\(count)")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    private func infoText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RunnerPulseDiagnosticsView: View {
    @ObservedObject var state: RunnerPulseState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Log e diagnostica", systemImage: "text.alignleft").font(.headline)
                Spacer()
                Button("Aggiorna") { state.reloadDiagnostics() }
                Button("Chiudi") { state.showDiagnostics = false }
            }
            Text("Fonte: \(state.hasLocalTelemetry ? "telemetria locale live" : state.configured ? "GitHub remoto / locale indisponibile" : "telemetria locale indisponibile")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(1...4, id: \.self) { id in
                let item = state.localSnapshots.first { $0.runner_id == id }
                let age = item.map { Int(max(0, Date().timeIntervalSince1970 - $0.updated_at)) }
                Text("runner-\(id): \(item?.isFresh() == true ? (item?.status ?? "sconosciuto") : "NON OSSERVATO") · heartbeat \(age.map { "\($0)s" } ?? "assente")")
                    .font(.system(size: 10, design: .monospaced))
            }
            Divider()
            Text("EVENTI RECENTI (METADATI)").font(.system(size: 10, weight: .semibold))
            let events = RunnerPulseDiagnostics.eventSummary(state.localSnapshots)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(events, id: \.self) { item in
                        Text(item).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if events.isEmpty {
                        Text("Nessun evento locale disponibile.").font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 115)
            Divider()
            Text("ERRORI OBSERVER (ULTIME 12 RIGHE)").font(.system(size: 10, weight: .semibold))
            ScrollView {
                Text(state.observerErrorLog)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
            Text("Non mostra output raw dei job o credenziali. Per il log completo usa Apri run GitHub dalla scheda del job.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 430)
    }
}

final class RunnerPulseAppDelegate: NSObject, NSApplicationDelegate {
    // Stable footprint prevents other menu bar items from shifting on every update.
    private let item = NSStatusBar.system.statusItem(withLength: 70)
    private let popover = NSPopover()
    private let state = RunnerPulseState()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "RunnerPulse")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "RunnerPulse · GitHub self-hosted runners"
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 430, height: 545)
        popover.contentViewController = NSHostingController(rootView: RunnerPulsePanel(state: state))
        state.$localSnapshots.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateStatus(self.state.snapshot)
            }
        }.store(in: &subscriptions)
        state.$snapshot.sink { [weak self] snap in
            DispatchQueue.main.async { [weak self] in self?.updateStatus(snap) }
        }.store(in: &subscriptions)
        updateStatus(state.snapshot)
        state.start()
    }

    private func updateStatus(_ snapshot: RunnerPulseSnapshot) {
        guard let button = item.button else { return }
        if state.hasLocalTelemetry {
            let live = state.localSnapshots.filter { $0.isFresh() }
            let active = live.filter { $0.isRunning }.count
            let counts = RunnerPulseLocalPolicy.overview(live)
            button.title = " \(counts.running)/4"
            button.contentTintColor = counts.other > 0 ? .systemOrange : nil
            button.toolTip = "RunnerPulse locale · \(counts.running) attivi, \(counts.idle) disponibili, \(counts.other) da verificare"
        } else if !state.configured {
            button.title = " —/4"
            button.contentTintColor = .systemOrange
            button.toolTip = state.hasStaleLocalTelemetry
                ? "RunnerPulse · telemetria locale scaduta (observer da verificare)"
                : "RunnerPulse · monitor locale non disponibile"
        } else {
            button.title = snapshot.running.isEmpty ? "" : " \(snapshot.running.count)"
            button.contentTintColor = state.hasStaleLocalTelemetry ||
                snapshot.offlineCount > 0 || !snapshot.errors.isEmpty ? .systemOrange : nil
            button.toolTip = state.hasStaleLocalTelemetry
                ? "RunnerPulse · telemetria locale scaduta, vista GitHub di fallback"
                : "RunnerPulse GitHub · \(snapshot.running.count) job in esecuzione, \(snapshot.queued.count) in coda"
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            state.refresh()
        }
    }
}

@main
struct RunnerPulseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = RunnerPulseAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
