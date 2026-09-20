import AppKit
import SwiftUI

@main
struct StudioFrontendApp: App {
    @NSApplicationDelegateAdaptor(FrontendAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("AhaKey Studio") {
            if !FrontendAppDelegate.isTesting {
                StudioWorkspaceView(model: delegate.model)
                    .task { delegate.model.start() }
            }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class FrontendAppDelegate: NSObject, NSApplicationDelegate {
    static var isTesting: Bool { NSClassFromString("XCTestCase") != nil }
    private var vibeBar: RuntimeVibeBarBridge?
    lazy var model: StudioModel = {
        let isMock = CommandLine.arguments.contains("--mock-runtime")
        // Mock drafts/operations cannot contaminate real-device state.
        let defaults = UserDefaults(suiteName: isMock ? "ai.ahakey.studio.frontend.mock" : "ai.ahakey.studio.frontend")!
        // Copy the old draft once, without running the legacy app or modifying its preferences.
        let legacyDomain = "com.xinyangzhang.AhaKey-Studio"
        #if DEBUG
        let legacyDomains = [legacyDomain + ".debug", legacyDomain]
        #else
        let legacyDomains = [legacyDomain]
        #endif
        let legacyDraft = isMock ? nil : legacyDomains.compactMap {
            UserDefaults.standard.persistentDomain(forName: $0)?["ahakey.studio.draft.v1"] as? Data
        }.first
        let drafts = StudioDraftStore(defaults: defaults, legacyDraft: legacyDraft)
        let client: RuntimeClient = isMock
            ? MockRuntimeClient(configuration: drafts.configuration(modes: AhaKeyModeSlot.allCases))
            : IPCRuntimeClient()
        return StudioModel(client: client, drafts: drafts, defaults: defaults, isMock: isMock)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTesting else { return }
        vibeBar = RuntimeVibeBarBridge(store: model.runtime)
        vibeBar?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !Self.isTesting { model.stop() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func frontendText(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Frontend", bundle: .main, comment: "")
}
