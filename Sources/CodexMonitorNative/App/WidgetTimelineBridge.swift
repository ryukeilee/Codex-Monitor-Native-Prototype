import Combine
import Foundation
import WidgetKit

@MainActor
final class WidgetTimelineBridge {
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        let saveState: () -> Void = { [weak appState] in
            guard let appState else { return }

            WidgetDisplayStateStore.save(
                WidgetDisplayState.make(
                    snapshot: appState.snapshot,
                    status: appState.displayStatus,
                    lastSuccessAt: appState.lastSuccessAt,
                    lastAttemptAt: appState.lastAttemptAt,
                    effectiveFiveHourResetAt: appState.effectiveFiveHourResetAt
                )
            )

            WidgetCenter.shared.reloadTimelines(ofKind: CodexMonitorWidgetConstants.kind)
        }

        appState.$snapshot
            .receive(on: RunLoop.main)
            .sink { _ in saveState() }
            .store(in: &cancellables)

        appState.$status
            .receive(on: RunLoop.main)
            .sink { _ in saveState() }
            .store(in: &cancellables)

        appState.$lastSuccessAt
            .receive(on: RunLoop.main)
            .sink { _ in saveState() }
            .store(in: &cancellables)

        appState.$lastAttemptAt
            .receive(on: RunLoop.main)
            .sink { _ in saveState() }
            .store(in: &cancellables)

        saveState()
    }
}
