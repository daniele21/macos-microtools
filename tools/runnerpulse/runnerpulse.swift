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
    private var localTimer: Timer?
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

    var hasLocalTelemetry: Bool { !localSnapshots.isEmpty }
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

    func openBackgroundLog() {
        let url = RunnerPulseBackgroundControl.logURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    func pollLocal() {
        localSnapshots = RunnerPulseLocalReader.load()
    }

    func start() {
        pollLocal()
        localTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollLocal()
        }
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
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.refresh()
        }
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
private struct RunnerResourceBars: View {
    let metrics: RunnerPulseResources?

    private func bar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(color)
                    .frame(width: max(0, geo.size.width * max(0, min(1, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    var body: some View {
        let active = metrics?.isValid() == true ? metrics : nil
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CPU").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(active.map { String(format: "%.0f%%", $0.cpu_percent) } ?? "—")
                        .monospacedDigit()
                }
                bar(active?.cpuFraction ?? 0,
                    color: (active?.cpu_percent ?? 0) >= 75 ? .orange : .cyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("RAM").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(active.map { String(format: "%.1f GB", $0.ramGB) } ?? "—")
                        .monospacedDigit()
                }
                bar(active?.ramFraction ?? 0,
                    color: (active?.ramFraction ?? 0) >= 0.75 ? .orange : .purple)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.top, 3)
        .help("Uso stimato di Runner.Worker e dei processi figli. CPU: % della capacità totale; RAM: RSS, può includere pagine condivise.")
    }
}

private struct LocalDashboard: View {
    let snapshots: [RunnerPulseLocalSnapshot]

    private func runnerColor(_ id: Int) -> Color {
        switch id {
        case 1: return .cyan
        case 2: return .purple
        case 3: return .yellow
        default: return .green
        }
    }

    private var live: [RunnerPulseLocalSnapshot] { snapshots.filter { $0.isFresh() } }
    private var events: [(Int, RunnerPulseLocalEvent)] {
        Array(snapshots.flatMap { snap in
            snap.recent_events.map { (snap.runner_id, $0) }
        }.sorted { $0.1.time > $1.1.time }.prefix(12))
    }

    private func eventTitle(_ event: RunnerPulseLocalEvent) -> String {
        switch event.kind {
        case "job_started": return "Avvio: \(event.name ?? "job")"
        case "job_completed": return "\(event.name ?? "job") · \(event.result ?? "completato")"
        case "step_started": return event.step ?? "Step"
        case "runner_started": return "Runner avviato"
        case "runner_stopped": return "Runner terminato"
        default: return event.kind
        }
    }

    var body: some View {
        HStack {
            Label("Locale · live", systemImage: "desktopcomputer")
                .foregroundStyle(Color.green)
            Spacer()
            Text("\(live.filter { $0.isRunning }.count) running")
            Text("\(live.filter { $0.isIdle }.count) idle")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("WORKERS").tracking(0.8)
                    Spacer()
                    Text("\(live.count)/4 osservati")
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)

                ForEach(1...4, id: \.self) { id in
                    let item = snapshots.first { $0.runner_id == id }
                    let fresh = item?.isFresh() == true
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fresh ? runnerColor(id) : Color.gray.opacity(0.4))
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("runner-\(id)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Text(fresh ? (item?.status.uppercased() ?? "UNKNOWN") : "NON OSSERVATO")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(fresh ? runnerColor(id) : Color.secondary)
                                Spacer()
                                if fresh, let start = item?.job?.started_at {
                                    Text(RunnerPulseCore.duration(
                                        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: start))))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if fresh, item?.status == "running", let job = item?.job {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(job.originTitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(job.attribution_status == "unresolved" ? Color.orange : Color.primary)
                                        .lineLimit(1)
                                    Text(job.triggerTitle)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.10), in: Capsule())
                                    Spacer(minLength: 0)
                                }
                                Text(job.name ?? "Job")
                                    .font(.system(size: 11)).lineLimit(1)
                                if let executor = job.execution_repository {
                                    Text("Workflow in \(executor)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let workflow = job.workflow {
                                    Text(workflow)
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                if let step = job.current_step {
                                    Label(step, systemImage: "chevron.right")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 12) {
                                    if let sha = job.sha, let commitURL = job.sourceCommitURL {
                                        Button("Commit \(String(sha.prefix(8)))") {
                                            openGitHub(commitURL)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    if let runURL = job.run_url, safeGitHubURL(runURL) != nil {
                                        Button("Apri run GitHub ↗") {
                                            openGitHub(runURL)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .font(.system(size: 9, design: .monospaced))
                                RunnerResourceBars(metrics: item?.resources)
                            } else {
                                Text(fresh ? (item?.status == "idle" ? "In ascolto di nuovi job" :
                                                "Sessione \(item?.status ?? "sconosciuta")")
                                    : "Nessun segnale recente · stato non verificato")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }

                if live.isEmpty {
                    Label("Monitor locale non aggiornato. Avvia runners dalla versione aggiornata di local-runner-infra.", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Progetto = codice testato · Workflow = repository che esegue la CI")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("ATTIVITÀ RECENTI").tracking(0.8)
                    Spacer()
                    Text("\(events.count) eventi")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).padding(.top, 6)

                ForEach(events.indices, id: \.self) { index in
                    let (id, event) = events[index]
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.kind == "job_completed" ? "checkmark.circle.fill" : "circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(event.kind == "job_completed"
                                ? (event.result?.lowercased() == "succeeded" ? Color.green : Color.red)
                                : runnerColor(id))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("runner-\(id) · \(eventTitle(event))")
                                .font(.system(size: 10)).lineLimit(2)
                            if let repo = event.repository {
                                Text(repo).font(.system(size: 9))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            } else if event.trigger_mode == "central_request" {
                                Text("Origine non verificata")
                                    .font(.system(size: 9)).foregroundStyle(Color.orange)
                            }
                            if let executor = event.execution_repository {
                                Text("Workflow in \(executor)")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            if let runURL = event.run_url, safeGitHubURL(runURL) != nil {
                                Button("Log GitHub ↗") { openGitHub(runURL) }
                                    .font(.system(size: 9))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Spacer()
                        Text(Date(timeIntervalSince1970: event.time)
                            .formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                if events.isEmpty {
                    Text("Nessun evento nella sessione corrente")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if state.refreshing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Button { state.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Aggiorna")
                Button { state.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Impostazioni")
            }
            .padding(16)
            Divider()
            if !state.hasLiveLocalSession {
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
                    Text("I runner saranno gestiti da launchd, senza finestra Terminale. Non usa --force e non duplica una sessione attiva.")
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
                LocalDashboard(snapshots: state.localSnapshots)
            } else if !state.configured {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Monitor locale", systemImage: "desktopcomputer").font(.headline)
                    Text("Nessuna telemetria locale ricevuta. Premi Avvia runner in background per avviare i worker senza Terminale, oppure controlla il log di avvio.")
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
        .frame(width: 430, height: 545)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $state.showSettings) {
            RunnerPulseSettings(state: state)
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

final class RunnerPulseAppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
            button.title = " \(active)/\(live.count)"
            button.contentTintColor = live.isEmpty ? .systemOrange : nil
            button.toolTip = "RunnerPulse locale · \(active) job su \(live.count) runner osservati"
        } else if !state.configured {
            button.title = ""
            button.contentTintColor = .systemOrange
            button.toolTip = "RunnerPulse · avvia il monitor locale con runners"
        } else {
            button.title = snapshot.running.isEmpty ? "" : " \(snapshot.running.count)"
            button.contentTintColor = snapshot.offlineCount > 0 || !snapshot.errors.isEmpty
                ? .systemOrange : nil
            button.toolTip = "RunnerPulse GitHub · \(snapshot.running.count) job in esecuzione, \(snapshot.queued.count) in coda"
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
