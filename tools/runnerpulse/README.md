# RunnerPulse · macOS menu bar GitHub Actions monitor

A zero-dependency, Swift-native menu bar tool showing **which self-hosted runner is busy, which repository and job is using it, the current step, queues, runtime and recent failures**. Built with Apple AppKit, SwiftUI, Foundation and Security; no background agent or telemetry daemon.

## Install

Requires macOS 13+ and Apple Command Line Tools:

~~~bash
git clone https://github.com/daniele21/macos-microtools.git
cd macos-microtools
make install-runnerpulse
open "$HOME/.local/opt/RunnerPulse.app"
~~~

For a clean rebuild after updating:

~~~bash
make refresh-runnerpulse
~~~

To run without installing: make build-runnerpulse, then open bin/RunnerPulse.app.

The app is menu-bar-only. Click the server icon (or "Set up") to open the panel, select the gear icon, and configure repositories and an access token.

### GitHub token

Create a **fine-grained personal access token** in GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens.

- Select each repository you monitor with **Actions: Read** (required for workflow runs and jobs). Private repositories need access.
- For a complete repository-owned runner inventory (idle, busy and offline), add repository **Administration: Read**. Without this permission, the app **continues showing self-hosted jobs** discovered through Actions, but cannot guarantee the complete runner list or offline status.
- For organization-owned runners, add the fine-grained **Self-hosted runners: Read** organization permission and write the organization name in the optional organizations field. The token must have access to that org.
- The app only issues read-only GET calls, never cancels/restarts jobs.

The token is saved in **macOS Keychain** as a device-only generic password, never in UserDefaults, the source tree, GitHub logs or analytics. Reopening settings leaves the token field blank intentionally; only paste a token to replace it. "Rimuovi token" deletes it.

Enter repositories one per line:

~~~text
daniele21/3d-rendering-llm
daniele21/macos-microtools
your-org/your-private-repo
~~~

You can add or remove repos without rebuilding. Repository and organization names (not secrets) are kept in UserDefaults.

## What is displayed

- **Workers:** online/idle, busy, offline from the runner inventory API. If only job data is available, cards are marked "job osservato" and cannot assert that all machines are listed.
- **In progress:** live workflow job, repository, branch, step, completed/total steps and elapsed time. The step count is **not a percent complete**.
- **Queue:** queued self-hosted jobs and, when the runner type is not known yet, unclassified queued workflows are labeled as such.
- **Anomalies:** in-progress job after 90 minutes marked "Lungo" (simple static threshold, not proof of a stuck job).
- **Recent failures:** up to five failed/timed-out/action-required workflows from the most recently listed runs.
- **Details:** clicking a known job/failure opens its GitHub web page.

Refresh is every **45 seconds while active** and **120 seconds while idle** (manual refresh available; other non-forced refreshes throttled at 15 seconds). No cloud backend and no local history. The app asks for at most 100 active/queued runs per repository and inspects at most 35 active workflows across the configured repos per refresh; it warns when coverage is truncated.

### Limits

- GitHub APIs do **not** expose worker CPU, RAM, GPU, logs on the worker filesystem or GCS objects through these endpoints; the app does not invent them.
- Organization-level inventory requires its own scope; repository-level inventory can omit organization runners.
- A runner may be busy with a job from an **unmonitored** repository. In that case the row says busy but job details are unavailable.
- If GitHub has not assigned a job, runner name/ID might be unavailable; RunnerPulse shows it in the queue.
- Workflow-level queued entries are **not necessarily self-hosted** until job labels become available; the UI explicitly notes that.
- API pagination and request budget are bounded. A warning is displayed instead of silently claiming complete coverage.
- No notifications or auto-start in v0.1.

## Build and validate

~~~bash
make test-runnerpulse
make build-runnerpulse
~~~

CI runs pure-Foundation model tests, AppKit/SwiftUI typecheck (via actual build), and bundle validation on a GitHub-hosted macOS runner. Functional auth/permissions and multiple live workers must be tested on your Mac.

## Uninstall

~~~bash
make uninstall-runnerpulse
~~~

This removes the app bundle, **not** the stored Keychain token and saved repository preferences. Delete the token first using the app Settings → Rimuovi token if you want to remove credentials.