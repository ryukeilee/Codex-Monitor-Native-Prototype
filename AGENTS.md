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

`Sources/CodexMonitorNative/Shared/WidgetDisplayState.swift` is compiled into both the SwiftPM app target and the Xcode widget target. Keep changes there compatible with both targets and preserve decoding compatibility for persisted widget payloads.

## Build, Test, and Development Commands

- `swift build -c debug`: build the app for local development
- `swift build -c release`: build the release binary
- `swift test`: run the full XCTest suite
- `swift test --filter <TestType-or-method>`: run the smallest relevant XCTest subset while iterating
- `./script/build_and_run.sh`: build, package, sign locally, and launch the app bundle
- `./script/build_and_run.sh --verify`: launch and assert the process starts
- `./script/build_and_run.sh --logs`: stream app process logs for manual debugging
- `./script/build_and_run.sh --telemetry`: stream app subsystem telemetry logs

For real quota data, the machine must have `codex` available, or `CODEX_BIN` / `CODEX_EXECUTABLE` must point to it. Use `CODEX_MONITOR_FORCE_MOCK=1` for deterministic mock data; the success and failure QA overrides are `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` and `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1`. The packaging script also builds the widget extension when `CodexMonitorWidgetExtension.xcodeproj` is present.

## Coding Style & Naming Conventions

Follow the existing Swift style: 4-space indentation, one top-level type per file when practical, and clear type-based filenames such as `RefreshScheduler.swift` or `StatusPopoverView.swift`. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep enum cases descriptive. Match the current directory split instead of introducing new layers casually.

No formatter or linter is currently checked in, so keep diffs small and style-consistent with neighboring files.

## Testing Guidelines

Use XCTest in `Tests/CodexMonitorNativeTests`. Name test files after the production type, and use method names like `testFailedRefreshKeepsLastSuccessfulSnapshot`. Add or update tests for behavior changes in refresh logic, persistence, scheduling, widget display state, and popover formatting.

Run the narrowest relevant test while iterating, then run `swift test` before handing off code changes. Also run `./script/build_and_run.sh --verify` for packaging, signing, app lifecycle, entitlement, or widget integration changes. For visible menu bar, popover, or widget changes, follow the relevant checks in `QA_CHECKLIST.md` and report any manual checks that remain.

## Commit & Pull Request Guidelines

Recent history mixes concise imperative subjects with conventional prefixes such as `fix:` and `feat:`. Prefer short, specific commit titles, for example `fix: preserve cached snapshot on auth failure`. PRs should explain the user-visible behavior change, list verification commands run, and include screenshots when menu bar or popover UI changes.

## Security & Configuration Tips

Never commit credentials, tokens, or local account data. Keep Codex executable overrides in environment variables, and validate failure paths with `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` or `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` during manual QA. Do not commit generated app bundles, widget products, or local signing artifacts.
