import AppKit
import SwiftUI

@main
struct AhaKeyStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("AhaKey Studio") {
            if !AppDelegate.isRunningTests {
                AhaKeyWorkspaceView(appDelegate: appDelegate)
            }
        }
        .windowStyle(.titleBar)
        .commands {
            // 主程序只有一个工作区，禁用 Command-N，避免 WindowGroup 累积多个完整视图树。
            CommandGroup(replacing: .newItem) { }
        }

        if #available(macOS 13.0, *) {
            MenuBarExtra("AhaKey", systemImage: "keyboard") {
                Button("打开主窗口") {
                    appDelegate.reopenMainWindow()
                }

                Divider()

                Button("退出 AhaKey Studio") {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
