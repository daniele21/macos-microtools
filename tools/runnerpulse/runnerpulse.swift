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

final class RunnerPulseState: ObservableObject {
    @Published var snapshot = RunnerPulseSnapshot()
    @Published var refreshing = false
    @Published var showSettings = false
    @Published var settingsError: String?
    @Published var repositoriesText: String
    @Published var organizationsText: String
    private var token: String?
    private var lastRequest: Date?
    private var generation = 0
    private var timer: Timer?

    init() {
        repositoriesText = UserDefaults.standard.string(forKey: "runnerpulse.repositories") ?? ""
        organizationsText = UserDefaults.standard.string(forKey: "runnerpulse.organizations") ?? ""
        token = RunnerPulseKeychain.read()
        showSettings = token == nil || RunnerPulseCore.validRepositories(repositoriesText).isEmpty
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
        snapshot = RunnerPulseSnapshot()
        showSettings = true
    }

    func start() { refresh(force: true) }

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
    @State private var newToken = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Impostazioni GitHub").font(.headline)
                Spacer()
                if state.configured {
                    Button("Chiudi") { state.showSettings = false }
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
            SecureField("github_pat_…", text: $newToken)
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
                    state.saveSettings(token: newToken)
                    newToken = ""
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 410)
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
            if !state.configured {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Collega GitHub").font(.headline)
                    Text("Aggiungi un token e i repository per vedere i job sui runner self-hosted.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Configura") { state.showSettings = true }
                        .buttonStyle(.borderedProminent)
                }.padding(20)
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
                if let date = state.snapshot.lastUpdated {
                    Text("Aggiornato \(date.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Non ancora aggiornato")
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
        state.$snapshot.sink { [weak self] snap in
            DispatchQueue.main.async { [weak self] in self?.updateStatus(snap) }
        }.store(in: &subscriptions)
        updateStatus(state.snapshot)
        state.start()
    }

    private func updateStatus(_ snapshot: RunnerPulseSnapshot) {
        guard let button = item.button else { return }
        if !state.configured {
            button.title = " Set up"
        } else {
            button.title = snapshot.running.isEmpty ? "" : " \(snapshot.running.count)"
        }
        button.contentTintColor = snapshot.offlineCount > 0 || !snapshot.errors.isEmpty
            ? .systemOrange : nil
        button.toolTip = "RunnerPulse · \(snapshot.running.count) job in esecuzione, \(snapshot.queued.count) in coda"
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
