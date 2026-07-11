# Metallic Menu Bar Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Codex Monitor menu bar popover as a compact red/black metallic panel inspired by the supplied reference while preserving existing quota and refresh business logic.

**Architecture:** Keep `AppState`, quota providers, refresh service, snapshot models, and formatting semantics intact. Refactor the SwiftUI presentation into focused decorative and information components, and make the existing `NSPopover` controller own dismissal/lifecycle hooks needed for Esc, outside-click, display-safe placement, and suspended panel-only animation/timers when hidden.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSPopover`, XCTest, Swift Package Manager, existing packaging/signing scripts.

---

### Task 1: Establish behavior and source-contract baselines

**Files:**
- Modify: `Tests/CodexMonitorNativeTests/StatusPopoverSnapshotTests.swift`
- Create or modify: focused popover lifecycle/source-contract tests under `Tests/CodexMonitorNativeTests/`

- [ ] Record the clean Git status and inspect the existing snapshot/source-contract expectations without changing business-model tests.
- [ ] Add failing tests/contracts for the required title/status, dual quota, reset/expiry, launch toggle, refresh/quit controls, panel lifecycle activity state, and Esc dismissal wiring.
- [ ] Run only the new/focused tests and confirm each failure is caused by missing presentation or lifecycle behavior.

### Task 2: Build the metallic SwiftUI panel

**Files:**
- Modify: `Sources/CodexMonitorNative/UI/StatusPopoverView.swift`
- Modify: `Sources/CodexMonitorNative/UI/QuotaSummaryView.swift`
- Create: focused visual components in `Sources/CodexMonitorNative/UI/` only where they keep one clear responsibility (panel background, reactor, quota gauge, information/action row).

- [ ] Replace the current GroupBox/disclosure-led composition with a fixed-width, display-safe red/black panel using layered gradients, subtle borders/highlights, and accessible contrast.
- [ ] Implement the top title and refresh state/time, left/right five-hour and weekly quota gauges, central reactor, reset count and earliest-expiry rows, launch-at-login toggle, and refresh/quit actions using existing `AppState` data/actions.
- [ ] Drive reactor motion and any live relative-time display only from an explicit `isPanelActive` lifecycle input; use reduced-motion awareness and avoid work while hidden.
- [ ] Keep reset-credit and quota fallback/error states legible without changing existing formatter/model semantics.
- [ ] Run the focused tests until green, then render/update the existing snapshot fixture path and visually inspect the output against the reference for hierarchy, clipping, and contrast.

### Task 3: Complete popover behavior and lifecycle

**Files:**
- Modify: `Sources/CodexMonitorNative/App/PopoverController.swift`
- Modify or create: focused tests/contracts under `Tests/CodexMonitorNativeTests/`

- [ ] Add Esc key dismissal while the popover is shown and remove every event monitor on close/deinit.
- [ ] Publish active/inactive lifecycle state to the SwiftUI root so close stops panel animation and panel-local time updates; preserve the app-wide quota `RefreshScheduler`.
- [ ] Keep outside-click dismissal and status-item anchoring, but clamp/choose sizing and placement from the active button/display visible frame so small, rotated, and secondary displays remain usable.
- [ ] Confirm reopening resumes panel-only activity without duplicate timers or event monitors.
- [ ] Run the focused lifecycle/source-contract tests until green.

### Task 4: Stabilize and verify

**Files:**
- Modify only files required by failures attributable to this goal.

- [ ] Review the focused diff for preservation of business logic, accessibility labels, reduced motion, keyboard dismissal, and monitor/timer cleanup.
- [ ] Run `swift build -c debug` once after stabilization.
- [ ] Run `swift test` once after stabilization and report test counts/failures.
- [ ] Run `./script/build_and_run.sh --verify` to package, locally sign, install/launch the `.app`, and verify process startup.
- [ ] In the installed app, manually exercise open/reopen, refresh, launch-at-login toggle state, outside click, Esc, quit affordance visibility (do not terminate before other checks), and move the status-item interaction across available displays where hardware permits; inspect logs/telemetry only if behavior is unclear.
- [ ] Capture a final screenshot or rendered snapshot as visual evidence and report any hardware-dependent multi-display check that could not be executed.
- [ ] Recheck `git status --short`; do not commit, push, or include generated `.build`/`dist` products in source changes.
