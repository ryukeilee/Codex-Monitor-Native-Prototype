import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetTimelineBridge {
    private let saveState: @MainActor (WidgetDisplayState) -> Void
    private let reloadTimelines: @MainActor () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lastSavedState: WidgetDisplayState?
    private var lastReloadedState: WidgetDisplayState?
    private weak var appState: AppState?

    init(
        appState: AppState,
        saveState: @escaping @MainActor (WidgetDisplayState) -> Void = { WidgetDisplayStateStore.save($0) },
        reloadTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: CodexMonitorWidgetConstants.kind)
        }
    ) {
        self.appState = appState
        self.saveState = saveState
        self.reloadTimelines = reloadTimelines

        appState.$presentationSnapshot
            .sink { [weak self] presentationSnapshot in
                self?.saveCurrentState(presentationSnapshot)
            }
            .store(in: &cancellables)
    }

    private func saveCurrentState(_ state: QuotaPresentationSnapshot, forceSave: Bool = false) {
        if forceSave || lastSavedState?.isEquivalent(to: state) != true {
            saveState(state)
            lastSavedState = state
        }

        guard state.status != .refreshing else {
            return
        }

        guard lastReloadedState?.isEquivalent(to: state) != true else {
            return
        }

        reloadTimelines()
        lastReloadedState = state
    }

    func shutdown() {
        guard let appState else { return }
        // AppState.shutdown() synchronously publishes the settled snapshot first,
        // so only its disk write is forced here; an equivalent reload was issued.
        saveCurrentState(appState.presentationSnapshot, forceSave: true)
    }
}
