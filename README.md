# Codex Monitor Native Prototype

Bootstrap repository for the Codex Monitor native prototype.

## Run

```bash
./script/build_and_run.sh
```

Useful variants:

```bash
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
