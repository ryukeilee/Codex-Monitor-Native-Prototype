# Codex Monitor Native Prototype QA Checklist

This checklist separates what is already proven by automated verification from
the final macOS behaviors that should be visually confirmed on a real desktop.

## Already Proven by Automation

- App launches as a menu bar style app with `LSUIElement = true`.
- The running process is background-only and has no regular windows.
- The menu bar status item shows a quota percentage and updates from persisted data.
- Clicking the status item opens the popover.
- Clicking the status item again closes the popover.
- The popover displays weekly quota, 5 hour quota, last refresh time, and status.
- Manual refresh succeeds and updates snapshot data.
- Forced refresh failure preserves the last successful snapshot and shows `Refresh Failed`.
- Snapshot persistence restores the latest successful snapshot across relaunches.
- Scheduler wiring fires periodic refresh ticks.
- Wake observer wiring responds to wake notifications.

## Manual macOS Verification

### 1. Full-Screen Behavior

1. Launch the app with `./script/build_and_run.sh`.
2. Open any regular macOS app such as TextEdit or Safari.
3. Put that app into full-screen mode.
4. Open the menu bar item from the full-screen Space.
5. Confirm the popover appears as a transient menu bar panel rather than a persistent floating window.
6. Click outside the popover inside the full-screen app.
7. Confirm the popover closes immediately.
8. Re-open the popover and then switch focus back to the full-screen app.
9. Confirm the full-screen app remains the primary surface and the popover does not stay stuck above it.

Expected result:
The popover behaves like a normal menu bar transient panel and does not remain as a persistent overlay on top of the full-screen app.

### 2. Idle Resource Spot Check

1. Launch the app with `./script/build_and_run.sh`.
2. Leave the popover closed for at least 10 seconds.
3. Run:

```bash
ps -axo pid,%cpu,rss,etime,comm | rg 'CodexMonitorNative.app/Contents/MacOS/CodexMonitorNative|CodexMonitorNative$'
```

Expected result:
CPU should be near `0.0` when idle, and memory should stay modest for a native utility-style app.

### 3. Sleep / Wake Spot Check

1. Launch the app.
2. Put the Mac to sleep and wake it again.
3. Open the menu bar popover or stream logs with:

```bash
./script/build_and_run.sh --telemetry
```

Expected result:
The app should attempt one refresh after wake and continue showing the last successful snapshot if that refresh fails.
