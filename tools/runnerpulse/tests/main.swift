import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let decoder = JSONDecoder()
let jobData = Data(#"""
{
  "id": 123, "name": "Render", "status": "in_progress", "conclusion": null,
  "runner_id": 17, "runner_name": "mac-studio", "labels": ["self-hosted", "macOS"],
  "html_url": "https://github.com/owner/project/actions/runs/24/job/123",
  "started_at": "2026-10-30T14:00:00Z",
  "steps": [
    {"name": "Checkout", "status": "completed", "conclusion": "success", "number": 1},
    {"name": "Blender", "status": "in_progress", "conclusion": null, "number": 2},
    {"name": "Upload", "status": "queued", "conclusion": null, "number": 3}
  ]
}
"""#.utf8)
let job = try decoder.decode(WorkflowJob.self, from: jobData)
check(RunnerPulseCore.isSelfHosted(job, knownRunnerIDs: []), "self-hosted label detection")
check(RunnerPulseCore.currentStep(job) == "Blender", "active step")
check(RunnerPulseCore.stepCount(job) == "1/3 steps", "step count is not percentage")
check(RunnerPulseCore.duration(job.started_at, now: RunnerPulseCore.date("2026-10-30T15:05:00Z")!) == "1h 5m", "duration")
check(RunnerPulseCore.isLongRunning(job.started_at, now: RunnerPulseCore.date("2026-10-30T15:31:00Z")!), "long duration")
check(!RunnerPulseCore.isLongRunning(job.started_at, now: RunnerPulseCore.date("2026-10-30T15:00:00Z")!), "normal duration")
check(RunnerPulseCore.date("2026-10-30T15:31:00.123Z") != nil, "ISO8601 fractional time")

let hostedData = Data(#"""
{"id": 7, "name": "hosted", "status": "queued", "conclusion": null, "runner_id": null,
"runner_name": null, "labels": ["ubuntu-latest"], "html_url": null, "started_at": null, "steps": null}
"""#.utf8)
let hosted = try decoder.decode(WorkflowJob.self, from: hostedData)
check(!RunnerPulseCore.isSelfHosted(hosted, knownRunnerIDs: []), "do not misclassify hosted")
check(RunnerPulseCore.isSelfHosted(hosted, knownRunnerIDs: [7]) == false, "nil runner ID cannot match")
check(RunnerPulseCore.validRepositories("org/a\norg/b,org/a\nbad-name") == ["org/a", "org/b"], "valid normalized repo list")
check(RunnerPulseCore.validOrganizations("example-org,example-org\nother") == ["example-org", "other"], "organization dedup")
let run = try decoder.decode(WorkflowRun.self, from: Data(#"""
{"id":24,"name":"test","display_title":"test","head_branch":"main",
"html_url":"https://github.com/owner/project/actions/runs/24",
"status":"in_progress","conclusion":null,"created_at":"2026-10-30T14:00:00Z","updated_at":null}
"""#.utf8))
let observed = ObservedJob(repository: "owner/project", run: run, job: job)
check(observed.branch == "main" && observed.runnerName == "mac-studio", "job to run attribution")
check(observed.id == "owner/project/24/123", "stable job id")


// Local Python monitor -> native Swift consumer JSON contract.
let localJSON = Data(#"""
{
  "schema_version": 1, "runner_id": 2, "session_id": "session-x", "pid": 512,
  "updated_at": 1000.0, "status": "running",
  "job": {
    "name": "analyze", "repository": "daniele21/source-repo",
    "sha": "bada551234", "workflow": "Central CI",
    "event_name": "repository_dispatch", "started_at": 950.0,
    "current_step": "Validate frozen source", "steps": ["Checkout", "Validate frozen source"]
  },
  "recent_events": [{
    "time": 990.0, "kind": "step_started", "name": "analyze",
    "repository": "daniele21/source-repo", "step": "Validate frozen source"
  }]
}
"""#.utf8)
let local = try JSONDecoder().decode(RunnerPulseLocalSnapshot.self, from: localJSON)
check(local.runner_id == 2 && local.job?.repository == "daniele21/source-repo", "local origin repo")
check(local.job?.current_step == "Validate frozen source", "local step")
check(local.isFresh(now: Date(timeIntervalSince1970: 1003.0)), "local live heartbeat")
check(!local.isFresh(now: Date(timeIntervalSince1970: 1010.0)), "stale is not online")
check(local.recent_events.count == 1, "local event decode")

check(local.resources == nil, "older snapshots without metrics remain readable")

let resourceSnapshot = Data(#"""
{
  "schema_version":1,"runner_id":1,"session_id":"session-m","pid":100,
  "updated_at":1000,"status":"running","job":null,
  "resources":{"cpu_percent":18.6,"ram_bytes":6442450944,"system_ram_bytes":17179869184,
               "process_count":3,"sampled_at":1000},
  "recent_events":[]
}
"""#.utf8)
let withResources = try JSONDecoder().decode(RunnerPulseLocalSnapshot.self, from: resourceSnapshot)
check(withResources.resources?.cpu_percent == 18.6, "decode aggregated CPU")
check(withResources.resources?.process_count == 3, "process tree count")
check(withResources.resources?.ramGB == 6.0, "bytes to GiB conversion")
check(withResources.resources?.isValid(now: Date(timeIntervalSince1970: 1004)) == true, "fresh metrics")
check(withResources.resources?.isValid(now: Date(timeIntervalSince1970: 1010)) == false, "stale metrics hidden")
check(abs((withResources.resources?.ramFraction ?? 0) - 0.375) < 0.0001, "RAM normalized to physical")


check(local.job?.trigger_mode == nil, "older v1 snapshots remain compatible")
check(local.job?.originTitle == "daniele21/source-repo", "legacy origin fallback")

let centralJSON = Data(#"""
{
  "schema_version": 1, "runner_id": 3, "session_id": "session-y", "pid": 123,
  "updated_at": 1000, "status": "running",
  "job": {
    "name": "test-on-mac", "repository": "daniele21/skill-engine",
    "sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "workflow": "Central Local CI", "event_name": "push",
    "execution_repository": "daniele21/local-runner-infra",
    "execution_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "trigger_mode": "central_request", "attribution_status": "verified",
    "run_url": "https://github.com/daniele21/local-runner-infra/actions/runs/38870605399",
    "started_at": 950, "current_step": "Execute source-owned Mac validation",
    "steps": []
  }, "recent_events": []
}
"""#.utf8)
let central = try decoder.decode(RunnerPulseLocalSnapshot.self, from: centralJSON)
check(central.job?.originTitle == "daniele21/skill-engine", "display true source repo")
check(central.job?.triggerTitle == "Richiesta centrale", "central request label")
check(central.job?.execution_repository == "daniele21/local-runner-infra", "separate workflow owner")
check(central.job?.sourceCommitURL ==
      "https://github.com/daniele21/skill-engine/commit/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "source link points to source SHA, not central SHA")
let unresolvedJSON = Data(#"""
{
  "schema_version": 1, "runner_id": 3, "session_id": "session-z", "pid": 124,
  "updated_at": 1000, "status": "running",
  "job": {
    "name": "test-on-mac", "repository": null, "sha": null,
    "workflow": "Central Local CI", "event_name": "push",
    "execution_repository": "daniele21/local-runner-infra",
    "execution_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "trigger_mode": "central_request", "attribution_status": "unresolved",
    "run_url": "https://github.com/daniele21/local-runner-infra/actions/runs/38870605399",
    "started_at": 950, "current_step": null, "steps": []
  }, "recent_events": []
}
"""#.utf8)
let unresolved = try decoder.decode(RunnerPulseLocalSnapshot.self, from: unresolvedJSON)
check(unresolved.job?.originTitle == "Origine non verificata", "do not misattribute unresolved requests")
check(unresolved.job?.sourceCommitURL == nil, "no false link for central event commit")


let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("runnerpulse-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

try localJSON.write(to: dir.appendingPathComponent("runner-2.json"))
check(RunnerPulseLocalReader.load(from: dir).count == 1, "single file per runner")
let invalid = Data(#"{"schema_version":5,"runner_id":1,"session_id":"x","pid":1,"updated_at":1000,"status":"idle","job":null,"recent_events":[]}"#.utf8)
try invalid.write(to: dir.appendingPathComponent("runner-1.json"))
check(RunnerPulseLocalReader.load(from: dir).count == 1, "reject unsupported schema")

try? FileManager.default.removeItem(at: dir)
print("RunnerPulse model checks passed")
