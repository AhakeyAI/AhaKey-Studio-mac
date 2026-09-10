import SwiftUI
import VibeBar

struct AhaKeyWorkspaceView: View {
    let appDelegate: AppDelegate
    @StateObject private var bleManager = AhaKeyBLEManager()
    @State private var vibeBarBridge = VibeBarBridge()

    var body: some View {
        RootView(bleManager: bleManager)
            .frame(minWidth: 1180, minHeight: 680)
            .onAppear {
                vibeBarBridge.attach(bleManager: bleManager) { [weak appDelegate] in
                    appDelegate?.reopenMainWindow()
                }
                VibeBarController.shared.start(state: vibeBarBridge.state)
            }
    }
}
