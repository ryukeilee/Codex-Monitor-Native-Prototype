# Repository Guidelines

## Project Structure & Module Organization

This repository is a macOS 14+ menu bar app built with Swift 6 and Swift Package Manager, plus a widget extension built from `CodexMonitorWidgetExtension.xcodeproj`.

Primary app code lives in `Sources/CodexMonitorNative` and is split by responsibility:

- `App/` for app lifecycle and status bar wiring
- `Core/` for quota refresh, scheduling, snapshots, and providers
- `UI/` for SwiftUI views and formatting helpers
- `Shared/` for shared models and state
- `System/` for platform integrations such as sleep/wake and launch-at-login

Widget extension sources live in `Sources/CodexMonitorWidgetExtension`.

Tests live in `Tests/CodexMonitorNativeTests`. Runtime assets and entitlements are in `Assets/`. Local packaging and run helpers are in `script/`. Manual verification guidance lives in `VERIFICATION.md` and `QA_CHECKLIST.md`. Built app bundles are emitted to `dist/`; treat `dist/` and `.build/` as generated output, not source.

The Xcode widget target directly compiles selected app sources from `Core/`, `Shared/`, and `UI/`; the authoritative list is the widget target's Sources build phase in `CodexMonitorWidgetExtension.xcodeproj/project.pbxproj`, not the SwiftPM target declaration. Keep listed files compatible with both compilation contexts, and update the Xcode project when a shared Widget dependency moves or is added. Preserve decoding compatibility for persisted app and Widget payloads unless an explicit migration is part of the task.

## Product Invariants

Unless a task explicitly changes the product contract:

- The menu bar title shows only a trusted weekly remaining percentage, or `--%` when none exists. Do not substitute five-hour, monthly, unknown, invalid, or mock values; during a failed refresh, the trusted weekly value from the last successful real snapshot remains valid for display.
- A failed real refresh keeps the last successful real snapshot and surfaces the typed failure state; it must not clear or relabel cached data as fresh.
- Cached real quota data may be restored, merged, or reused only when its validated account/session boundary matches the current Codex identity. Missing, malformed, changed, or unverifiable identity must fail closed so one account's quota is never shown for another account.
- The popover, status-item tooltip, and Widget derive quota windows from the shared presentation path. Keep ordering, filtering, labels, progress, reset times, and overflow behavior semantically aligned.

## Build, Test, and Development Commands

- `swift build -c debug`: build the app for local development
- `swift build -c release`: build the release binary
- `swift test`: run the full XCTest suite
- `swift test --filter <TestType-or-method>`: run the smallest relevant XCTest subset while iterating
- `./script/build_and_run.sh`: build, package, sign locally, and launch the app bundle
- `./script/build_and_run.sh --debug`: build and launch the packaged app under LLDB
- `./script/build_and_run.sh --verify`: run the unified installation acceptance flow; it replaces the app at `INSTALL_APP_PATH`, launches it, and verifies app/Widget versions, the running path, and Widget binding
- `./script/build_and_run.sh --logs`: stream app process logs for manual debugging
- `./script/build_and_run.sh --telemetry`: stream app subsystem telemetry logs

For real quota data, the machine must have a `codex` executable that supports `codex app-server`, or `CODEX_BIN` / `CODEX_EXECUTABLE` must point to it. The app uses the command's default stdio transport and must not assume a `--stdio` flag exists. Use `CODEX_MONITOR_FORCE_MOCK=1` for deterministic mock data; the success and failure QA overrides are `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` and `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1`. The packaging script also builds the widget extension when `CodexMonitorWidgetExtension.xcodeproj` is present.

## Coding Style & Naming Conventions

Follow the existing Swift style: 4-space indentation, one top-level type per file when practical, and clear type-based filenames such as `RefreshScheduler.swift` or `StatusPopoverView.swift`. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep enum cases descriptive. Match the current directory split instead of introducing new layers casually.

No formatter or linter is currently checked in, so keep diffs small and style-consistent with neighboring files.

## Testing and Definition of Done

Use XCTest in `Tests/CodexMonitorNativeTests`. Name test files after the production type, and use method names like `testFailedRefreshKeepsLastSuccessfulSnapshot`. Add or update behavior-focused tests for changes to refresh and RPC handling, account/session boundary handling, persistence and migrations, scheduling and resource lifecycles, shared presentation logic, Widget state, or popover behavior. Account-bound cache changes must cover matching identity, missing or malformed identity, account/session changes, and identity changes during an in-flight refresh. Do not use source-string assertions or artifact existence alone as proof of UI behavior.

Run the narrowest relevant test while iterating. Before handing off code changes, run `swift test` and `swift build -c debug`. Also run `./script/build_and_run.sh --verify` for packaging, signing, installed-app lifecycle, entitlement, or widget integration changes; note that this command stops the existing app and replaces the installed bundle. For visible menu bar, popover, or widget changes, follow the relevant checks in `QA_CHECKLIST.md` and report every manual check not performed. If a required gate cannot run, report the reason and the exact unverified gate.

## Review Guidelines

- Treat regressions against the Product Invariants as correctness issues, not cosmetic differences.
- When a file is shared with the widget target, review and validate both compilation contexts. If it changes persisted models, also verify payload compatibility.
- For persistence, identity boundaries, app-server RPC, concurrency, or lifecycle changes, require explicit coverage of the relevant mismatch, failure, cancellation, recovery, or shutdown path.
- Keep generated output out of review scope unless the task explicitly concerns packaging artifacts.

## Commit & Pull Request Guidelines

Recent history mixes concise imperative subjects with conventional prefixes such as `fix:` and `feat:`. Prefer short, specific commit titles, for example `fix: preserve cached snapshot on auth failure`. PRs should explain the user-visible behavior change, list verification commands run, and include screenshots when menu bar or popover UI changes.

## Security & Configuration Tips

Never commit credentials, tokens, raw account/session identifiers, auth-file contents, or local account data. Persist or log only the minimum non-reversible identity material required for account-bound cache safety. Keep Codex executable overrides in environment variables, and validate failure paths with `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` or `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` during manual QA. Do not commit generated app bundles, Widget products, or local signing artifacts.
