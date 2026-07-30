import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetTimelineBridge {
    private let saveState: @MainActor (WidgetDisplayState) -> Bool
    private let reloadTimelines: @MainActor () -> Void
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var lastPropagatedState: WidgetDisplayState?
    private var hasWrittenInitialState = false

    init(
        appState: AppState,
        saveState: @escaping @MainActor (WidgetDisplayState) -> Bool = { WidgetDisplayStateStore.save($0) },
        reloadTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: CodexMonitorWidgetConstants.kind)
        }
    ) {
        self.saveState = saveState
        self.reloadTimelines = reloadTimelines
        self.appState = appState

        appState.$stateEvent
            .sink { [weak self] stateEvent in
                self?.propagate(stateEvent)
            }
            .store(in: &cancellables)
    }

    /// Stops receiving host-state changes. Safe to call more than once during
    /// overlapping termination and ownership-handoff paths.
    func stop() {
        cancellables.removeAll()
    }

    /// Forces an immediate save of the current app state to the shared widget
    /// store and reloads all widget timelines. Unlike the regular Combine-driven
    /// propagation, this bypasses the `isEquivalent(to:)` deduplication check so
    /// the widget always sees the latest state after a forced sync (e.g. on app
    /// startup or after an identity change).
    func forceSync() {
        guard let appState else { return }
        let state = appState.presentationSnapshot
        guard saveState(state) else {
            AppLogger.snapshot.error("Widget state force-sync save failed; not reloading timelines")
            return
        }
        lastPropagatedState = state
        hasWrittenInitialState = true
        reloadTimelines()
        AppLogger.snapshot.info("Widget state force-synced: status=\(state.status.rawValue, privacy: .public) weekly=\(state.snapshot.weeklyQuotaPercent)%")
    }

    private func propagate(_ event: AppStateEvent) {
        let state = event.presentationSnapshot
        let requiresTemporalReload = event.updateReason == .temporalReconciliation

        // The timeline continues projecting the last settled payload while a
        // request is in flight. Persisting this transient state can strand the
        // Widget at "refreshing" if the host exits before publishing a result.
        if state.status == .refreshing {
            if requiresTemporalReload {
                reloadTimelines()
            }
            return
        }

        let stateChanged = lastPropagatedState?.isEquivalent(to: state) != true

        if stateChanged {
            let saveSuccess = saveState(state)
            if saveSuccess {
                lastPropagatedState = state
                hasWrittenInitialState = true
            } else {
                AppLogger.snapshot.error("Widget state save failed; not reloading timelines with stale data")
                return
            }
        }

        guard stateChanged || (requiresTemporalReload && hasWrittenInitialState) else {
            return
        }

        reloadTimelines()
    }
}
