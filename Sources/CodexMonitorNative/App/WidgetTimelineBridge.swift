import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetTimelineBridge {
    private let saveState: @MainActor (WidgetDisplayState) -> Void
    private let reloadTimelines: @MainActor () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var pendingSaveTask: Task<Void, Never>?
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

        appState.$snapshot
            .sink { [weak self] _ in self?.requestSave() }
            .store(in: &cancellables)

        appState.$status
            .sink { [weak self] _ in self?.requestSave() }
            .store(in: &cancellables)

        appState.$lastSuccessAt
            .sink { [weak self] _ in self?.requestSave() }
            .store(in: &cancellables)

        appState.$lastAttemptAt
            .sink { [weak self] _ in self?.requestSave() }
            .store(in: &cancellables)

        saveCurrentState()
    }

    private func requestSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }

            self.saveCurrentState()
        }
    }

    private func saveCurrentState() {
        guard let appState else { return }

        let state = WidgetDisplayState.make(
            snapshot: appState.snapshot,
            status: appState.displayStatus,
            lastSuccessAt: appState.lastSuccessAt,
            lastAttemptAt: appState.lastAttemptAt,
            effectiveFiveHourResetAt: appState.effectiveFiveHourResetAt
        )

        saveState(state)

        guard state.status != .refreshing else {
            return
        }

        reloadTimelines()
    }

    deinit {
        pendingSaveTask?.cancel()
    }
}
