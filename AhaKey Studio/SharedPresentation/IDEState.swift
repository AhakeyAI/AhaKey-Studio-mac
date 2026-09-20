import Foundation

/// IDE 状态枚举（原厂 ClaudeState）
/// 发送到键盘后驱动 LED 颜色变化
enum IDEState: UInt8, CaseIterable, Codable, Identifiable {
    case notification = 0        // 通知
    case permissionRequest = 1   // 等待授权
    case postToolUse = 2         // 工具执行完毕
    case preToolUse = 3          // 工具执行中
    case sessionStart = 4        // 会话开始
    case stop = 5                // 已停止
    case taskCompleted = 6       // 任务完成
    case userPromptSubmit = 7    // 用户提交
    case sessionEnd = 8          // 会话结束

    var label: String {
        switch self {
        case .notification: return String(localized: "text.bc6b282b2770", defaultValue: "0 通知")
        case .permissionRequest: return String(localized: "text.c2fd5bcc1a8f", defaultValue: "1 等待授权")
        case .postToolUse: return String(localized: "text.437d096ac568", defaultValue: "2 工具完毕")
        case .preToolUse: return String(localized: "text.ca288bb0b6aa", defaultValue: "3 工具执行")
        case .sessionStart: return String(localized: "text.8a15d32a9ea4", defaultValue: "4 会话开始")
        case .stop: return String(localized: "text.b009468f6dd9", defaultValue: "5 停止")
        case .taskCompleted: return String(localized: "text.c3aaf25a6e86", defaultValue: "6 任务完成")
        case .userPromptSubmit: return String(localized: "text.4e5f8006cebe", defaultValue: "7 用户提交")
        case .sessionEnd: return String(localized: "text.c5257b168384", defaultValue: "8 会话结束")
        }
    }

    var id: UInt8 { rawValue }

    static let workflowOrder: [IDEState] = [
        .sessionStart,
        .userPromptSubmit,
        .preToolUse,
        .permissionRequest,
        .postToolUse,
        .notification,
        .taskCompleted,
        .stop,
        .sessionEnd,
    ]

    var shortLabel: String {
        switch self {
        case .notification: return String(localized: "text.4b6ded8a7f18", defaultValue: "通知")
        case .permissionRequest: return String(localized: "text.79209170acff", defaultValue: "等待授权")
        case .postToolUse: return String(localized: "text.726e8f082af7", defaultValue: "工具完毕")
        case .preToolUse: return String(localized: "text.a548992cfa33", defaultValue: "工具执行")
        case .sessionStart: return String(localized: "text.62e40dc9441f", defaultValue: "会话开始")
        case .stop: return String(localized: "text.ca4d973c0b00", defaultValue: "停止")
        case .taskCompleted: return String(localized: "text.324225eef1d7", defaultValue: "任务完成")
        case .userPromptSubmit: return String(localized: "text.34b0e1d0eaa5", defaultValue: "用户提交")
        case .sessionEnd: return String(localized: "text.b95efcee516e", defaultValue: "会话结束")
        }
    }
}
