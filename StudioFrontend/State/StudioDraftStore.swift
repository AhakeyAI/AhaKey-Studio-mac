import Combine
import Foundation

@MainActor
final class StudioDraftStore: ObservableObject {
    struct SavedDraft: Codable {
        var version = 1
        var draft: AhaKeyStudioDraft
        var brightness: Int
    }
    @Published var draft: AhaKeyStudioDraft { didSet { save() } }
    @Published var brightness: Int { didSet { save() } }
    @Published private(set) var persistenceError: String?
    private let defaults: UserDefaults
    private let key = "studio.frontend.draft.v1"

    init(defaults: UserDefaults, legacyDraft: Data? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(SavedDraft.self, from: data), saved.version == 1 {
            draft = saved.draft
            brightness = saved.brightness
        } else if let data = legacyDraft, let old = try? JSONDecoder().decode(AhaKeyStudioDraft.self, from: data) {
            draft = old
            brightness = old.draft(for: .mode0).lightBar.brightness
        } else {
            draft = .default
            brightness = 35
        }
        save()
    }

    func updateMode(_ mode: AhaKeyModeSlot, _ update: (inout AhaKeyModeDraft) -> Void) {
        var value = draft.draft(for: mode)
        update(&value)
        draft.updateMode(value)
    }

    func configuration(modes: [AhaKeyModeSlot]) -> DeviceConfiguration {
        DeviceConfiguration(device: .init(brightnessPercent: brightness), modes: modes.map { slot in
            let mode = draft.draft(for: slot)
            return ModeConfiguration(mode: slot.rawValue, keys: AhaKeyKeyRole.allCases.map { role in
                let key = mode.key(for: role)
                let action: KeyAction
                if key.usesMacro {
                    action = .macro(steps: key.macro.map { step in
                        switch step.action {
                        case .downKey: return .init(type: "keyDown", keyCode: Int(step.param))
                        case .upKey: return .init(type: "keyUp", keyCode: Int(step.param))
                        case .delay: return .init(type: "delay", delayMs: Int(step.param) * 3)
                        case .upAllKeys: return .init(type: "releaseAll")
                        case .noOp: return .init(type: "noOp")
                        }
                    })
                } else if key.shortcut.isConfigured {
                    action = .shortcut(modifiers: key.shortcut.orderedModifiers.map {
                        switch $0 {
                        case .command: return "gui"
                        case .option: return "alt"
                        case .control: return "control"
                        case .shift: return "shift"
                        }
                    }, keyCode: Int(key.shortcut.keyCode))
                } else { action = .disabled }
                return KeyConfiguration(role: ["voice", "approve", "reject", "submit"][role.rawValue], action: action, description: key.description)
            }, lights: mode.lightBar.stateMappings.map {
                LightMapping(state: Self.stateName($0.state), effect: $0.effect.rawValue)
            })
        })
    }

    static func stateName(_ state: IDEState) -> String {
        switch state {
        case .notification: return "notification"
        case .permissionRequest: return "permissionRequest"
        case .postToolUse: return "postToolUse"
        case .preToolUse: return "preToolUse"
        case .sessionStart: return "sessionStart"
        case .stop: return "stop"
        case .taskCompleted: return "taskCompleted"
        case .userPromptSubmit: return "userPromptSubmit"
        case .sessionEnd: return "sessionEnd"
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(SavedDraft(draft: draft, brightness: brightness)), forKey: key)
            persistenceError = nil
        } catch { persistenceError = "DRAFT_SAVE_FAILED" }
    }
}
