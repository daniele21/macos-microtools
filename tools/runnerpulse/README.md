# RunnerPulse · macOS menu bar GitHub Actions monitor

A zero-dependency, Swift-native menu bar tool showing **which self-hosted runner is busy, which repository and job is using it, the current step, queues, runtime and recent failures**. Built with Apple AppKit, SwiftUI, Foundation and Security; no background agent or telemetry daemon.

## Local-first dashboard (preferred on your runner Mac)

RunnerPulse now defaults to a **read-only local dashboard**, not the GitHub
access-token setup modal. It consumes a secure per-runner JSON snapshot written
by your existing foreground runner monitor in the separate repository
"local-runner-infra". You do not need a GitHub token or repository list to see
these 4 local workers.

To enable, first update local-runner-infra and its
scripts/runner_monitor/status.py bridge, then restart its foreground "runners"
command **only after any running jobs finish**. Stopping an existing
interactive monitor can terminate the runners it manages; RunnerPulse itself
does not launch or stop them.

~~~bash
cd "$HOME/Personal/local-runner-infra"
git pull --ff-only
# Restart your existing "runners" session when it is safe.
~~~

Then in this microtools repository:

~~~bash
make refresh-runnerpulse
~~~

The app reads runner-1.json .. runner-4.json under
"~/Library/Application Support/RunnerPulse/runners/" once a second and shows
runner-colored cards, origin repository, current step, elapsed time, and recent
job events. Each file gets a heartbeat every ~1s. If the writer stops or
is older than 6 seconds, the card is "NON OSSERVATO" rather than claiming the
runner is idle/offline. Missing runner files are shown as unknown, not offline.

The GitHub token settings remain available from the gear icon and are optional.
The existing REST API dashboard is a fallback if local snapshots do not exist.
Local mode does not attempt to show the GitHub queue, because a local worker
cannot know the complete remote queue from its logs.

**Privacy:** telemetry contains job metadata and recent lifecycle events,
not raw logs, job output, credentials or repository contents. Files are
written atomically with owner-only permissions. RunnerPulse never creates a
second runner process.

## Understanding job provenance

The local dashboard now separates **source project** (the code under test)
from **workflow owner** (the repository where the Actions job exists).
For a verified job, it displays the source repository, the 8-character
source SHA, its complete workflow name, the execution repository, and
an action to open the authoritative GitHub Actions run. The trigger is
shown as **Dal progetto** for `repository_dispatch`, **Richiesta centrale**
for a versioned central request, or **Workflow diretto** for native
project workflows.

The source commit link points to the verified source SHA, **not** to the
central infrastructure commit. If the monitor cannot verify attribution
(e.g., missing GitHub CLI permissions or ambiguous request), the card says
**Origine non verificata**. A GitHub run link can still be displayed.
Recent activity includes the same execution ownership and a link to logs.

The Python-side monitor in `local-runner-infra` publishes optional fields in
the existing `schema_version: 1` JSON; older v1 snapshots continue decoding.
No GitHub token is required inside RunnerPulse for this local view. To deploy:
update the Python monitor and restart foreground `runners` **after current
jobs have finished**, then update this repository and run
`make test-runnerpulse && make refresh-runnerpulse`.

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

## Command Line Tools compatibility

SwiftUI in recent macOS SDKs defines `@State` through the `SwiftUIMacros` compiler plugin. The standalone Command Line Tools may ship the SDK interface but not this plugin, causing `SwiftUIMacros.StateMacro` build errors. RunnerPulse avoids `@State` entirely: the transient secure token input is bound to an existing `@Published` property of the `@ObservedObject` state model. The draft is cleared when settings are saved/closed, and the token is persisted only in macOS Keychain.

After updating the repository, run:

~~~bash
make refresh-runnerpulse
~~~

The build still requires the Apple Command Line Tools. CI checks that `@State` is not reintroduced, in addition to compiling the macOS app on GitHub Actions. If other compiler errors persist, capture `swiftc --version`, `xcode-select -p` and `xcrun --show-sdk-version` when reporting them.

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