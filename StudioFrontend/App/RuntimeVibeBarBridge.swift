import AppKit
import Combine
import VibeBar

@MainActor
final class RuntimeVibeBarBridge {
    let state = VibeBarState()
    private var observation: AnyCancellable?

    init(store: RuntimeStore) {
        state.onOpenMainWindow = {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: \.canBecomeMain)?.makeKeyAndOrderFront(nil)
        }
        observation = store.$devices.sink { [weak self] devices in
            guard let self else { return }
            let device = devices.first
            self.state.keyboardConnected = device?.isReady == true
            self.state.deviceName = device?.name
            self.state.batteryLevel = device?.batteryPercent ?? 0
            self.state.batteryKnown = device?.batteryPercent != nil
            self.state.leverKnown = device?.isReady == true && ["automatic", "manual"].contains(device?.lever ?? "")
            self.state.leverIsAuto = self.state.leverKnown && device?.lever == "automatic"
        }
    }

    func start() { VibeBarController.shared.start(state: state) }
}
