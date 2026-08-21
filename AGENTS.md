# Repository Guidelines

## Project Structure & Module Organization

This repository is a macOS 14+ menu bar app built with Swift 6 and Swift Package Manager, plus a widget extension built from `CodexMonitorWidgetExtension.xcodeproj`.

Primary app code lives in `Sources/CodexMonitorNative` and is split by responsibility:

- `App/` — app lifecycle and `@main` entry point (`CodexMonitorNativeApp.swift`), `AppDelegate` NSApplication delegate with single-instance ownership claiming, installation identity revalidation, popover/activation lifecycle, status bar wiring, popover controller, and widget timeline bridge
- `Core/` — quota refresh, scheduling, snapshot persistence, Codex RPC discovery, providers (real/mock), reset credit details, and usage trend storage/analysis
- `UI/` — SwiftUI popover views, metallic panel decorative components, reactor visualization, formatting helpers, interaction policy, self-check snapshot, and usage trend view/formatting
- `Shared/` — shared models (`AppState`, `WidgetDisplayState`), data source protocols, quota decision/status types, health diagnostic (`RealQuotaHealthDiagnostic`), OSLog subsystem/category definitions (`AppLogger`), and widget presentation helpers
- `System/` — platform integrations: single-instance arbitration (`SingleInstanceCoordinator`), installation identity and authority (`AppInstallationIdentity` + `AppInstallationAuthority`), launch-at-login, sleep/wake, network reachability, system clock monitoring, Codex auth boundary observer, and quota anomaly notification

Widget extension source lives in `Sources/CodexMonitorWidgetExtension/CodexMonitorWidget.swift`.

Tests live in `Tests/CodexMonitorNativeTests` (currently 577 tests, 0 failures). Runtime assets and entitlements are in `Assets/`. Local packaging and run helpers are in `script/`. Manual verification guidance lives in `VERIFICATION.md` and `QA_CHECKLIST.md`. Implementation plans live in `docs/superpowers/plans/`. Pi agent worktree sessions are tracked in `.claude/worktrees/`. Built app bundles are emitted to `dist/`; treat `dist/`, `.build/`, and `build/` as generated output, not source.

The Xcode widget target directly compiles selected app sources; the authoritative list is the widget target's Sources build phase in `CodexMonitorWidgetExtension.xcodeproj/project.pbxproj`, not the SwiftPM target declaration. Currently it includes files from:

| Source file | Module area |
|---|---|
| `CodexMonitorWidget.swift` | Widget extension |
| `WidgetDisplayState.swift` | Shared |
| `QuotaSnapshot.swift` | Core |
| `QuotaDataSource.swift` | Shared |
| `QuotaRefreshStatus.swift` | Shared |
| `RealQuotaHealthDiagnostic.swift` | Shared |
| `StatusPopoverFormatting.swift` | UI |
| `MechanicalEnergyCore.swift` | UI |
| `WidgetPresentation.swift` | Shared |

Keep listed files compatible with both compilation contexts (SwiftPM for the app target, Xcode for the widget extension), and update the Xcode project when a shared Widget dependency moves or is added. Preserve decoding compatibility for persisted app and Widget payloads unless an explicit migration is part of the task.

## Product Invariants

Unless a task explicitly changes the product contract:

- The menu bar title shows only a trusted weekly remaining percentage, or `--%` when none exists. Do not substitute five-hour, monthly, unknown, invalid, or mock values; during a failed refresh, the trusted weekly value from the last successful real snapshot remains valid for display.
- A failed real refresh keeps the last successful real snapshot and surfaces the typed failure state; it must not clear or relabel cached data as fresh.
- Cached real quota data may be restored, merged, or reused only when its validated account/session boundary matches the current Codex identity. Missing, malformed, changed, or unverifiable identity must fail closed so one account's quota is never shown for another account. Fail-closed invalidation must also be published when persistence is unavailable: a persistence write failure must not revive a real snapshot whose account/session ownership is no longer valid, and the Widget must drop old real recovery sources whenever the host explicitly invalidates them, even when the primary state file cannot be replaced or decoded.
- The popover, status-item tooltip, and Widget derive quota windows from the shared presentation path. Keep ordering, filtering, labels, progress, reset times, and overflow behavior semantically aligned.
- Usage trend history and anomaly alerts consume only trusted real weekly quota samples inside the validated account/session boundary. Quota resets and anomalous jumps start a new trend baseline, and no alert fires for mock data, unbound snapshots, or mismatched identity samples.

## Build, Test, and Development Commands

- `swift build -c debug`: build the app for local development
- `swift build -c release`: build the release binary
- `swift test`: run the full XCTest suite (currently 577 tests)
- `swift test --filter <TestType-or-method>`: run the smallest relevant XCTest subset while iterating
- `./script/build_and_run.sh`: build, package, sign locally, and launch the app bundle
- `./script/build_and_run.sh --debug`: build and launch the packaged app under LLDB
- `./script/build_and_run.sh --verify`: run the unified installation acceptance flow; it replaces the app at `INSTALL_APP_PATH`, launches it, and verifies app/Widget versions, the running path, and Widget binding
- `./script/build_and_run.sh --logs`: stream app process logs for manual debugging
- `./script/build_and_run.sh --telemetry`: stream app subsystem telemetry logs
- `./script/build-and-install.sh`: legacy compatibility entry point that forwards to `./script/build_and_run.sh --verify`

The packaging script also builds the widget extension when `CodexMonitorWidgetExtension.xcodeproj` is present.

Optional environment variables for the build script:
- `BUILD_CONFIGURATION=debug|release` — build configuration override (default: debug)
- `INSTALL_APP_PATH=/path/to/App.app` — override default install target

For real quota data, the machine must have a `codex` executable that supports `codex app-server`, or `CODEX_BIN` / `CODEX_EXECUTABLE` must point to it. The app uses the command's default stdio transport and must not assume a `--stdio` flag exists.

Mock/QA overrides:
- `CODEX_MONITOR_FORCE_MOCK=1` — deterministic mock data
- `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` — force refresh success path
- `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` — force refresh failure path



## Widget Extension Signing & Registration

The macOS Widget Extension must be signed with a development or distribution certificate (not ad-hoc) and **must include `com.apple.security.app-sandbox`** in its entitlements. The entitlements file is `Assets/CodexMonitorWidgetExtension.entitlements`. Without sandbox, PlugInKit (pkd) rejects the plugin with:

```
pkd: rejecting; Ignoring mis-configured plugin at [...CodexMonitorWidgetExtension.appex]: plug-ins must be sandboxed
```

When this happens, the widget does not appear in the "Edit Widgets" panel and chronod never discovers it. The build script always signs the widget with the configured `WIDGET_CODESIGN_IDENTITY` (default: Apple Development) and `--entitlements` pointing to the canonical entitlements file.

### Troubleshooting Widget Registration

If the widget is missing from the widget gallery after `--verify`:

1. Check system logs for pkd rejection:
   ```bash
   log show --predicate 'sender contains "pkd" AND message contains "CodexMonitorWidgetExtension"' --last 10m --style compact
   ```
2. Verify the widget's signed entitlements:
   ```bash
   codesign -d --entitlements :- /Applications/CodexMonitorNative.app/Contents/PlugIns/CodexMonitorWidgetExtension.appex
   ```
3. If the app fails to launch with "App installation validation failed closed", clear the stored installation identity and retry:
   ```bash
   defaults delete com.ryukeilee.CodexMonitorNativePrototype "codex.monitor.native.preferredInstallation.v1"
   ```
4. Confirm chronod recognizes the widget:
   ```bash
   log show --predicate 'message contains "CodexMonitorQuotaWidget" AND message contains "reload: succeeded"' --last 10m --style compact
   ```

## Coding Style & Naming Conventions

Follow the existing Swift style: 4-space indentation, one top-level type per file when practical, and clear type-based filenames such as `RefreshScheduler.swift` or `StatusPopoverView.swift`. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep enum cases descriptive. Match the current directory split instead of introducing new layers casually.

No formatter or linter is currently checked in, so keep diffs small and style-consistent with neighboring files.

## Testing and Definition of Done

Use XCTest in `Tests/CodexMonitorNativeTests`. Name test files after the production type, and use method names like `testFailedRefreshKeepsLastSuccessfulSnapshot`. The current test suite (577 tests) covers the following areas:

| Test area | Representative test files |
|---|---|
| Refresh & RPC | `QuotaRefreshServiceTests`, `RealQuotaProviderTests`, `CodexAppServerProtocolTests`, `CodexExecutableResolverTests` |
| Account/session boundary | `CodexAuthBoundaryObserverTests`, `CodexAuthIdentityReaderTests`, `QuotaAccountBoundaryTestSupport` |
| Persistence & state | `AppStateTests`, `QuotaSnapshotTests` (via provider tests), `AppInstallationAuthorityTests` |
| Scheduling & lifecycle | `RefreshSchedulerTests`, `SleepWakeObserverTests`, `SystemClockObserverTests`, `NetworkReachabilityObserverTests` |
| Single-instance arbitration | `SingleInstanceCoordinatorTests`, `AppDelegateLifecycleTests` |
| Launch-at-login | `LaunchAtLoginManagerTests` |
| UI presentation | `StatusPopoverFormattingTests`, `StatusPopoverBehaviorTests`, `StatusSelfCheckSnapshotTests`, `MechanicalEnergyCoreLayoutTests` |
| Widget state & timeline | `WidgetPresentationTests`, `WidgetTimelineBridgeTests` |
| Reset credits | `ResetCreditsDetailProviderTests` |
| Usage trend & anomaly alerts | `UsageTrendTests` |
| Refresh reliability probes | `ReliabilityProbeTests` |
| Deterministic fault scenarios | `DeterministicFaultScenarioTests` |
| Refresh consistency regression | `RefreshConsistencyRegressionTests` |
| Quota decision logic | `QuotaDecisionTests` |

Add or update behavior-focused tests for changes in these areas. Account-bound cache changes must cover matching identity, missing or malformed identity, account/session changes, and identity changes during an in-flight refresh. Do not use source-string assertions or artifact existence alone as proof of UI behavior.

Run the narrowest relevant test while iterating. Before handing off code changes, run `swift test` and `swift build -c debug`. Also run `./script/build_and_run.sh --verify` for packaging, signing, installed-app lifecycle, entitlement, or widget integration changes; note that this command stops the existing app and replaces the installed bundle. For visible menu bar, popover, or widget changes, follow the relevant checks in `QA_CHECKLIST.md` and report every manual check not performed. If a required gate cannot run, report the reason and the exact unverified gate.

## Maintenance Loop

Existing-feature maintenance work follows the evidence-driven Maintenance Loop defined in `.agent/loop.md` (Observe → Evidence → Decide → Execute → Verify → Record). Read `.agent/rules.md` (agent working boundary), `.agent/memory.md` (long-term project knowledge), and `.agent/history.md` (recent loop records) before making any change. This file (`AGENTS.md`) remains the authoritative project specification; `.agent/loop.md` is the executable maintenance workflow layered on top of it.

## Review Guidelines

- Treat regressions against the Product Invariants as correctness issues, not cosmetic differences.
- When a file is shared with the widget target, review and validate both compilation contexts. If it changes persisted models, also verify payload compatibility.
- For persistence, identity boundaries, app-server RPC, concurrency, or lifecycle changes, require explicit coverage of the relevant mismatch, failure, cancellation, recovery, or shutdown path.
- Keep generated output out of review scope unless the task explicitly concerns packaging artifacts.

## Commit & Pull Request Guidelines

Recent history mixes concise imperative subjects with conventional prefixes such as `fix:`, `feat:`, and chore-like descriptions. Prefer short, specific commit titles, for example `fix: preserve cached snapshot on auth failure`. PRs should explain the user-visible behavior change, list verification commands run, and include screenshots when menu bar or popover UI changes.

## Security & Configuration Tips

Never commit credentials, tokens, raw account/session identifiers, auth-file contents, or local account data. Persist or log only the minimum non-reversible identity material required for account-bound cache safety. Keep Codex executable overrides in environment variables, and validate failure paths with `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` or `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` during manual QA. Do not commit generated app bundles, Widget products, or local signing artifacts.

## Pi & Worktree Context

This project uses Pi coding agent with `.claude/worktrees/` for isolated worktree sessions (currently: `icon-fix`, `real-quota-migration`, `stability-hardening`). Each worktree corresponds to a separate Pi agent session with its own branch and scratch state. Treat `.claude/` as a generated/working directory — do not track in version control (included in `.gitignore`). Implementation plans for larger feature work live under `docs/superpowers/plans/` in markdown format with task-level checklists.
