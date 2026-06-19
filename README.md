# Codex Monitor Native Prototype

Bootstrap repository for the Codex Monitor native prototype.

This repository is a Swift Package app, so use `swift build` for command-line
builds. There is no checked-in `.xcodeproj` or `.xcworkspace`, which means
`xcodebuild -scheme "Codex Monitor Native"` will not work here.

## Build

```bash
swift build -c debug
swift build -c release
```

## Run

```bash
./script/build_and_run.sh
```

## Install

Use the Release bundle from the same script entrypoint:

```bash
BUILD_CONFIGURATION=release ./script/build_and_run.sh --verify
sudo rm -rf "/Applications/Codex Monitor Native.app"
sudo ditto "$PWD/dist/CodexMonitorNative.app" "/Applications/Codex Monitor Native.app"
open -n "/Applications/Codex Monitor Native.app"
```

Useful variants:

```bash
BUILD_CONFIGURATION=release ./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

To force the simulated refresh path during manual verification:

```bash
CODEX_MONITOR_FORCE_REFRESH_SUCCESS=1 ./script/build_and_run.sh
CODEX_MONITOR_FORCE_REFRESH_FAILURE=1 ./script/build_and_run.sh
```

## Repository Hygiene

- Keep secrets out of the repository.
- Use the leak-prevention rules in `.gitleaks.toml` before pushing.
- Prefer environment variables or local-only config files for credentials.
