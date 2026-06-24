# Repository Guidelines

## Project Structure & Module Organization

This repository is a macOS menu bar app built with Swift Package Manager. App code lives in `Sources/CodexMonitorNative` and is split by responsibility:

- `App/` for app lifecycle and status bar wiring
- `Core/` for quota refresh, scheduling, snapshots, and providers
- `UI/` for SwiftUI views and formatting helpers
- `Shared/` for shared models and state
- `System/` for platform integrations such as sleep/wake and launch-at-login

Tests live in `Tests/CodexMonitorNativeTests`. Runtime assets are in `Assets/`. Local packaging and run helpers are in `script/`. Built app bundles are emitted to `dist/`; do not treat generated files there as source.

## Build, Test, and Development Commands

- `swift build -c debug`: build the app for local development
- `swift build -c release`: build the release binary
- `swift test`: run the full XCTest suite
- `./script/build_and_run.sh`: build, package, and launch the app bundle
- `./script/build_and_run.sh --verify`: launch and assert the process starts
- `./script/build_and_run.sh --logs`: stream app logs for manual debugging

For real quota data, the machine must have `codex` available, or `CODEX_BIN` / `CODEX_EXECUTABLE` must point to it.

## Coding Style & Naming Conventions

Follow the existing Swift style: 4-space indentation, one top-level type per file when practical, and clear type-based filenames such as `RefreshScheduler.swift` or `StatusPopoverView.swift`. Use `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and keep enum cases descriptive. Match the current directory split instead of introducing new layers casually.

No formatter or linter is currently checked in, so keep diffs small and style-consistent with neighboring files.

## Testing Guidelines

Use XCTest in `Tests/CodexMonitorNativeTests`. Name test files after the production type, and use method names like `testFailedRefreshKeepsLastSuccessfulSnapshot`. Add or update tests for behavior changes in refresh logic, persistence, scheduling, and popover formatting. Run `swift test` before submitting changes.

## Commit & Pull Request Guidelines

Recent history mixes concise imperative subjects with conventional prefixes such as `fix:` and `feat:`. Prefer short, specific commit titles, for example `fix: preserve cached snapshot on auth failure`. PRs should explain the user-visible behavior change, list verification commands run, and include screenshots when menu bar or popover UI changes.

## Security & Configuration Tips

Never commit credentials, tokens, or local account data. Keep Codex executable overrides in environment variables, and validate failure paths with `CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1` or `CODEX_MONITOR_FORCE_REFRESH_FAILURE=1` during manual QA.
