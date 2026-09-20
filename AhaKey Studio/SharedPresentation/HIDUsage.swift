import Foundation

/// 常用 HID Usage ID 与界面按键名称。
enum HIDUsage {
    // 修饰键
    static let leftControl: UInt8 = 0xE0
    static let leftShift: UInt8 = 0xE1
    static let leftAlt: UInt8 = 0xE2
    static let leftGUI: UInt8 = 0xE3
    static let rightControl: UInt8 = 0xE4
    static let rightShift: UInt8 = 0xE5
    static let rightAlt: UInt8 = 0xE6
    static let rightGUI: UInt8 = 0xE7

    // 功能键
    static let f1: UInt8 = 0x3A
    static let f2: UInt8 = 0x3B
    static let f3: UInt8 = 0x3C
    static let f4: UInt8 = 0x3D
    static let f5: UInt8 = 0x3E
    static let f6: UInt8 = 0x3F
    static let f7: UInt8 = 0x40
    static let f8: UInt8 = 0x41
    static let f9: UInt8 = 0x42
    static let f10: UInt8 = 0x43
    static let f11: UInt8 = 0x44
    static let f12: UInt8 = 0x45
    static let f13: UInt8 = 0x68
    static let f14: UInt8 = 0x69
    static let f15: UInt8 = 0x6A
    static let f16: UInt8 = 0x6B
    static let f17: UInt8 = 0x6C
    static let f18: UInt8 = 0x6D
    static let f19: UInt8 = 0x6E
    static let f20: UInt8 = 0x6F

    // 基础键
    static let enter: UInt8 = 0x28
    static let escape: UInt8 = 0x29
    static let backspace: UInt8 = 0x2A
    static let tab: UInt8 = 0x2B
    static let space: UInt8 = 0x2C
    static let capsLock: UInt8 = 0x39
    static let deleteForward: UInt8 = 0x4C
    static let insert: UInt8 = 0x49
    static let home: UInt8 = 0x4A
    static let pageUp: UInt8 = 0x4B
    static let end: UInt8 = 0x4D
    static let pageDown: UInt8 = 0x4E
    static let minus: UInt8 = 0x2D
    static let equal: UInt8 = 0x2E
    static let leftBracket: UInt8 = 0x2F
    static let rightBracket: UInt8 = 0x30
    static let backslash: UInt8 = 0x31
    static let semicolon: UInt8 = 0x33
    static let quote: UInt8 = 0x34
    static let grave: UInt8 = 0x35
    static let comma: UInt8 = 0x36
    static let period: UInt8 = 0x37
    static let slash: UInt8 = 0x38
    static let keypadSlash: UInt8 = 0x54
    static let keypadAsterisk: UInt8 = 0x55
    static let keypadMinus: UInt8 = 0x56
    static let keypadPlus: UInt8 = 0x57
    static let keypadEnter: UInt8 = 0x58
    static let keypad1: UInt8 = 0x59
    static let keypad2: UInt8 = 0x5A
    static let keypad3: UInt8 = 0x5B
    static let keypad4: UInt8 = 0x5C
    static let keypad5: UInt8 = 0x5D
    static let keypad6: UInt8 = 0x5E
    static let keypad7: UInt8 = 0x5F
    static let keypad8: UInt8 = 0x60
    static let keypad9: UInt8 = 0x61
    static let keypad0: UInt8 = 0x62
    static let keypadPeriod: UInt8 = 0x63

    // 方向键
    static let rightArrow: UInt8 = 0x4F
    static let leftArrow: UInt8 = 0x50
    static let downArrow: UInt8 = 0x51
    static let upArrow: UInt8 = 0x52

    /// 所有可用的键码选项（用于 UI 选择器）
    static let allOptions: [(name: String, code: UInt8)] = [
        // 功能键
        ("F1", f1), ("F2", f2), ("F3", f3), ("F4", f4),
        ("F5", f5), ("F6", f6), ("F7", f7), ("F8", f8),
        ("F9", f9), ("F10", f10), ("F11", f11), ("F12", f12),
        ("F13", f13), ("F14", f14), ("F15", f15), ("F16", f16),
        ("F17", f17), ("F18", f18), ("F19", f19), ("F20", f20),
        // 基础键
        ("Enter", enter), ("Escape", escape), ("Backspace", backspace),
        ("Tab", tab), ("Space", space), ("CapsLock", capsLock),
        ("Delete", deleteForward), ("Insert", insert), ("Home", home),
        ("End", end), ("Page Up", pageUp), ("Page Down", pageDown),
        ("-", minus), ("=", equal), ("[", leftBracket), ("]", rightBracket),
        ("\\", backslash), (";", semicolon), ("'", quote), ("`", grave),
        (",", comma), (".", period), ("/", slash),
        // 方向键
        ("→", rightArrow), ("←", leftArrow), ("↓", downArrow), ("↑", upArrow),
        // 字母键
        ("A", 0x04), ("B", 0x05), ("C", 0x06), ("D", 0x07),
        ("E", 0x08), ("F", 0x09), ("G", 0x0A), ("H", 0x0B),
        ("I", 0x0C), ("J", 0x0D), ("K", 0x0E), ("L", 0x0F),
        ("M", 0x10), ("N", 0x11), ("O", 0x12), ("P", 0x13),
        ("Q", 0x14), ("R", 0x15), ("S", 0x16), ("T", 0x17),
        ("U", 0x18), ("V", 0x19), ("W", 0x1A), ("X", 0x1B),
        ("Y", 0x1C), ("Z", 0x1D),
        // 数字键
        ("1", 0x1E), ("2", 0x1F), ("3", 0x20), ("4", 0x21),
        ("5", 0x22), ("6", 0x23), ("7", 0x24), ("8", 0x25),
        ("9", 0x26), ("0", 0x27),
        // 修饰键
        ("Left Ctrl", leftControl), ("Left Shift", leftShift),
        ("Left Alt", leftAlt), ("Left Cmd", leftGUI),
        ("Right Ctrl", rightControl), ("Right Shift", rightShift),
        ("Right Alt", rightAlt), ("Right Cmd", rightGUI),
        // 小键盘
        ("Keypad /", keypadSlash), ("Keypad *", keypadAsterisk),
        ("Keypad -", keypadMinus), ("Keypad +", keypadPlus),
        ("Keypad Enter", keypadEnter), ("Keypad 0", keypad0),
        ("Keypad 1", keypad1), ("Keypad 2", keypad2), ("Keypad 3", keypad3),
        ("Keypad 4", keypad4), ("Keypad 5", keypad5), ("Keypad 6", keypad6),
        ("Keypad 7", keypad7), ("Keypad 8", keypad8), ("Keypad 9", keypad9),
        ("Keypad .", keypadPeriod),
    ]

    static let primaryOptions = allOptions

    /// 根据键码查找名称
    static func name(for code: UInt8) -> String {
        allOptions.first { $0.code == code }?.name ?? String(format: "0x%02X", code)
    }

    static func hidCode(forMacKeyCode keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case 0: return 0x04 // A
        case 1: return 0x16 // S
        case 2: return 0x07 // D
        case 3: return 0x09 // F
        case 4: return 0x0B // H
        case 5: return 0x0A // G
        case 6: return 0x1D // Z
        case 7: return 0x1B // X
        case 8: return 0x06 // C
        case 9: return 0x19 // V
        case 11: return 0x05 // B
        case 12: return 0x14 // Q
        case 13: return 0x1A // W
        case 14: return 0x08 // E
        case 15: return 0x15 // R
        case 16: return 0x1C // Y
        case 17: return 0x17 // T
        case 18: return 0x1E // 1
        case 19: return 0x1F // 2
        case 20: return 0x20 // 3
        case 21: return 0x21 // 4
        case 22: return 0x23 // 6
        case 23: return 0x22 // 5
        case 24: return equal
        case 25: return 0x26 // 9
        case 26: return 0x24 // 7
        case 27: return minus
        case 28: return 0x25 // 8
        case 29: return 0x27 // 0
        case 30: return rightBracket
        case 31: return 0x12 // O
        case 32: return 0x18 // U
        case 33: return leftBracket
        case 34: return 0x0C // I
        case 35: return 0x13 // P
        case 36: return enter
        case 37: return 0x0F // L
        case 38: return 0x0D // J
        case 39: return quote
        case 40: return 0x0E // K
        case 41: return semicolon
        case 42: return backslash
        case 43: return comma
        case 44: return slash
        case 45: return 0x11 // N
        case 46: return 0x10 // M
        case 47: return period
        case 48: return tab
        case 49: return space
        case 50: return grave
        case 51: return backspace
        case 53: return escape
        case 54: return rightGUI
        case 55: return leftGUI
        case 56: return leftShift
        case 57: return capsLock
        case 58: return leftAlt
        case 59: return leftControl
        case 60: return rightShift
        case 61: return rightAlt
        case 62: return rightControl
        case 63: return f19 // Fn/Globe reports as a function modifier on many Mac keyboards.
        case 64: return f17
        case 65: return keypadPeriod
        case 67: return keypadAsterisk
        case 69: return keypadPlus
        case 71: return 0x53 // Keypad Clear / Num Lock
        case 75: return keypadSlash
        case 76: return keypadEnter
        case 78: return keypadMinus
        case 79: return f18
        case 80: return f19
        case 82: return keypad0
        case 83: return keypad1
        case 84: return keypad2
        case 85: return keypad3
        case 86: return keypad4
        case 87: return keypad5
        case 88: return keypad6
        case 89: return keypad7
        case 90: return f20
        case 91: return keypad8
        case 92: return keypad9
        case 96: return f5
        case 97: return f6
        case 98: return f7
        case 99: return f3
        case 100: return f8
        case 101: return f9
        case 103: return f11
        case 105: return f13
        case 106: return f16
        case 107: return f14
        case 109: return f10
        case 111: return f12
        case 113: return f15
        case 115: return home
        case 116: return pageUp
        case 117: return deleteForward
        case 118: return f4
        case 119: return end
        case 120: return f2
        case 121: return pageDown
        case 122: return f1
        case 123: return leftArrow
        case 124: return rightArrow
        case 125: return downArrow
        case 126: return upArrow
        default: return nil
        }
    }
}

extension String {
    /// 设备 LCD 描述只稳定支持 ASCII；非 ASCII 字符会在设备端变成乱码。
    func sanitizedASCII(maxLength: Int) -> String {
        var result = String()
        result.reserveCapacity(min(maxLength, count))

        for scalar in unicodeScalars where scalar.isASCII {
            guard result.utf8.count < maxLength else { break }
            result.unicodeScalars.append(scalar)
        }

        return result
    }

    var containsNonASCII: Bool {
        unicodeScalars.contains(where: { !$0.isASCII })
    }
}
