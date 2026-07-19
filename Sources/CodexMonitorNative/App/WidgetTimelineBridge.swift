import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetTimelineBridge {
    private let saveState: @MainActor (WidgetDisplayState) -> Void
    private let reloadTimelines: @MainActor () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lastPropagatedState: WidgetDisplayState?

    init(
        appState: AppState,
        saveState: @escaping @MainActor (WidgetDisplayState) -> Void = { WidgetDisplayStateStore.save($0) },
        reloadTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: CodexMonitorWidgetConstants.kind)
        }
    ) {
        self.saveState = saveState
        self.reloadTimelines = reloadTimelines

        appState.$stateEvent
            .sink { [weak self] stateEvent in
                self?.propagate(stateEvent)
            }
            .store(in: &cancellables)
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
            saveState(state)
            lastPropagatedState = state
        }

        guard stateChanged || requiresTemporalReload else {
            return
        }

        reloadTimelines()
    }
}
