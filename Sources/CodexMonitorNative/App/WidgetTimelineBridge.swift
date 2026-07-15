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
                self?.propagate(stateEvent.presentationSnapshot)
            }
            .store(in: &cancellables)
    }

    private func propagate(_ state: QuotaPresentationSnapshot) {
        guard lastPropagatedState?.isEquivalent(to: state) != true else {
            return
        }

        saveState(state)
        lastPropagatedState = state

        guard state.status != .refreshing else {
            return
        }

        reloadTimelines()
    }
}
