import Foundation

/// AhaKey-X1 BLE 协议编解码
///
/// 帧格式: AA BB [cmd:1] [data:N] CC DD
/// 原厂代码: build_device_frame(cmd, data) = FRAME_HEAD + bytes([cmd]) + data + FRAME_TAIL
enum AhaKeyCommand {
    static let header: [UInt8] = [0xAA, 0xBB]
    static let trailer: [UInt8] = [0xCC, 0xDD]
    static let oledWidth = 160
    static let oledHeight = 80
    static let oledFrameSlotSize = 28_672
    static let oledFactoryReservedSlots = 10
    static let oledModeCount = 4
    static let oledMaxFramesPerMode = 70
    static let oledMaxFrames = oledMaxFramesPerMode
    /// 用户选择的 GIF 源文件大小上限（避免过大文件拖慢解码与 BLE 上传）。
    static let oledMaxSourceFileBytes = 2 * 1024 * 1024 // 2 MB
    /// 固件端要求每个 prepareWrite 的 address 必须 4096 字节对齐（flash 扇区大小）。
    /// 原厂 Python 客户端也用 4096 作为写入分块大小，一次 prepareWrite 刚好擦写一个扇区。
    static let oledChunkSize = 4096
    /// BLE data 特征单次 writeValue 的软上限（与固件接收 FIFO 匹配，不走协商 MTU）。
    static let oledPacketSize = 180

    // 设备命令 (DeviceCmd)
    static let cmdChangeName: UInt8 = 0x01
    static let cmdChangeAppearance: UInt8 = 0x02
    static let cmdSaveConfig: UInt8 = 0x04
    static let cmdUpdateCustomKey: UInt8 = 0x73
    static let cmdPrepareWrite: UInt8 = 0x80
    static let cmdWriteResult: UInt8 = 0x81
    static let cmdUpdatePic: UInt8 = 0x82
    static let cmdReadPicState: UInt8 = 0x83
    static let cmdUpdateState: UInt8 = 0x90  // IDE 状态 → LED 变色
    static let cmdPreviewLightEffect: UInt8 = 0x91 // 直接预览灯效，不保存配置
    static let cmdSetLightMapping: UInt8 = 0x84  // per-mode per-state LED 映射
    static let cmdSetBrightness: UInt8 = 0x85    // 全局 WS2812 亮度 1-100
    static let cmdSetWorkMode: UInt8 = 0x92      // 远程切换工作模式 0-3

    static func oledStartIndex(forMode mode: UInt8) -> UInt16 {
        UInt16(oledFactoryReservedSlots + Int(min(3, mode)) * oledMaxFramesPerMode)
    }

    // 按键子类型 (KeySubType)
    static let subShortcut: UInt8 = 0x73
    static let subMacro: UInt8 = 0x74
    static let subDescription: UInt8 = 0x75

    /// 设备状态查询 → AA BB 00 CC DD
    static func queryDeviceStatus() -> Data {
        Data(header + [0x00] + trailer)
    }

    /// 保存配置到设备 Flash → AA BB 04 CC DD
    static func saveConfig() -> Data {
        Data(header + [cmdSaveConfig] + trailer)
    }

    /// 键码写入 → AA BB 73 73 [mode] [key_index] [hid_codes...] CC DD
    /// - Parameters:
    ///   - mode: 工作模式 0-3
    ///   - keyIndex: 0=Key1, 1=Key2, 2=Key3, 3=Key4
    ///   - hidCodes: HID Usage ID 数组（修饰键在前，普通键在后，最多 98 字节）
    static func setKeyMapping(mode: UInt8 = 0, keyIndex: UInt8, hidCodes: [UInt8]) -> Data {
        let payload: [UInt8] = [subShortcut, mode, keyIndex] + hidCodes
        return Data(header + [cmdUpdateCustomKey] + payload + trailer)
    }

    /// 描述写入 → AA BB 73 75 [mode] [key_index] [utf8...] CC DD
    /// - Parameters:
    ///   - mode: 工作模式 0-3
    ///   - keyIndex: 0=Key1, 1=Key2, 2=Key3, 3=Key4
    ///   - text: 显示在 LCD 上的按键描述（最多 20 字节 ASCII）
    static func setKeyDescription(mode: UInt8 = 0, keyIndex: UInt8, text: String) -> Data {
        let textBytes = Array(text.sanitizedASCII(maxLength: 20).utf8)
        let payload: [UInt8] = [subDescription, mode, keyIndex] + textBytes
        return Data(header + [cmdUpdateCustomKey] + payload + trailer)
    }

    /// 宏写入 → AA BB 73 74 [mode] [key_index] [action, param, ...] CC DD
    static func setKeyMacro(mode: UInt8 = 0, keyIndex: UInt8, macroData: [UInt8]) -> Data {
        let payload: [UInt8] = [subMacro, mode, keyIndex] + macroData
        return Data(header + [cmdUpdateCustomKey] + payload + trailer)
    }

    /// 修改设备名称 → AA BB 01 [utf8...] CC DD
    static func changeName(_ name: String) -> Data {
        let nameBytes = Array(name.utf8.prefix(21))
        return Data(header + [cmdChangeName] + nameBytes + trailer)
    }

    /// 修改 BLE Appearance → AA BB 02 [appearance] CC DD
    static func changeAppearance(_ value: UInt8) -> Data {
        Data(header + [cmdChangeAppearance, value] + trailer)
    }

    /// 读取图片状态 → AA BB 83 [mode] CC DD
    static func readPicState(mode: UInt8) -> Data {
        Data(header + [cmdReadPicState, mode] + trailer)
    }

    /// 预备写入大块数据 → AA BB 80 [flag:1] [chunk_len:2 LE] [address:4 LE] CC DD
    static func prepareWrite(flag: UInt8 = 0x00, chunkLength: Int, address: UInt32) -> Data {
        let payload: [UInt8] = [
            flag,
            UInt8(chunkLength & 0xFF),
            UInt8((chunkLength >> 8) & 0xFF),
            UInt8(address & 0xFF),
            UInt8((address >> 8) & 0xFF),
            UInt8((address >> 16) & 0xFF),
            UInt8((address >> 24) & 0xFF),
        ]
        return Data(header + [cmdPrepareWrite] + payload + trailer)
    }

    /// 更新 LCD 动画参数 → AA BB 82 [mode] [start_index:2 LE] [frame_count:2 LE] [time_delay:2 LE] CC DD
    static func updatePicture(mode: UInt8, startIndex: UInt16, frameCount: UInt16, timeDelayMs: UInt16) -> Data {
        let payload: [UInt8] = [
            mode,
            UInt8(startIndex & 0xFF),
            UInt8((startIndex >> 8) & 0xFF),
            UInt8(frameCount & 0xFF),
            UInt8((frameCount >> 8) & 0xFF),
            UInt8(timeDelayMs & 0xFF),
            UInt8((timeDelayMs >> 8) & 0xFF),
        ]
        return Data(header + [cmdUpdatePic] + payload + trailer)
    }

    /// IDE 状态同步 → AA BB 90 [state] CC DD
    /// 驱动键盘 LED 变色，反映 Claude/Cursor 当前状态
    static func updateState(_ state: IDEState) -> Data {
        Data(header + [cmdUpdateState, state.rawValue] + trailer)
    }

    /// per-mode per-state LED 灯效映射 → AA BB 84 [mode] [state0_light]...[state8_light] CC DD
    static func setLightMapping(mode: UInt8, stateEffects: [UInt8]) -> Data {
        var effects = Array(stateEffects.prefix(9))
        while effects.count < 9 { effects.append(0) }
        return Data(header + [cmdSetLightMapping, mode] + effects + trailer)
    }

    /// 全局 WS2812 亮度 → AA BB 85 [brightness] CC DD
    static func setBrightness(_ value: UInt8) -> Data {
        let clamped = max(1, min(100, value))
        return Data(header + [cmdSetBrightness, clamped] + trailer)
    }

    /// 直接预览某个灯效 → AA BB 91 [effect] CC DD
    static func previewLightEffect(_ effect: UInt8) -> Data {
        Data(header + [cmdPreviewLightEffect, effect] + trailer)
    }

    /// 切换工作模式 → AA BB 92 [mode] CC DD
    static func setWorkMode(_ mode: UInt8) -> Data {
        Data(header + [cmdSetWorkMode, min(3, mode)] + trailer)
    }
}

/// 设备状态响应解析结果
struct AhaKeyDeviceStatus {
    let battery: Int
    let signal: Int
    let firmwareMain: Int
    let firmwareSub: Int
    let workMode: Int
    let lightMode: Int
    let switchState: Int
    let brightness: Int
}

struct AhaKeyPictureState {
    let mode: Int
    let startIndex: Int
    let picLength: Int
    let frameInterval: Int
    let allModeMaxPic: Int
}

/// AhaKey 协议响应解析器
enum AhaKeyResponseParser {
    static func parseCommandResponse(_ data: Data) -> (cmd: UInt8, status: UInt8, payload: Data)? {
        guard isProtocolFrame(data), data.count >= 6 else { return nil }
        let cmd = data[2]
        let status = data[3]
        let payload = data.count > 6 ? Data(data[4 ..< data.count - 2]) : Data()
        return (cmd, status, payload)
    }

    /// 尝试从 notify 数据中解析设备状态
    /// 实际格式: AA BB [cmd_echo] [battery] [signal] [fw_main] [fw_sub] [work] [light] [switch] ... CC DD
    /// 第一个 payload 字节是命令回显（0x00），真实数据从第二字节开始
    static func parseDeviceStatus(_ data: Data) -> AhaKeyDeviceStatus? {
        // header(2) + cmd_echo(1) + 7 bytes status + trailer(2) = 12 bytes minimum
        guard data.count >= 12,
              data[0] == 0xAA, data[1] == 0xBB,
              data[data.count - 2] == 0xCC, data[data.count - 1] == 0xDD else {
            return nil
        }

        let payload = data[2 ..< data.count - 2]
        // payload[0] = command echo (0x00), skip it
        guard payload.count >= 8, payload[payload.startIndex] == 0x00 else { return nil }

        let base = payload.startIndex + 1 // skip cmd echo
        let brightness = payload.count >= 9 ? Int(payload[base + 7]) : 35
        return AhaKeyDeviceStatus(
            battery: Int(payload[base]),
            signal: Int(Int8(bitPattern: payload[base + 1])),
            firmwareMain: Int(payload[base + 2]),
            firmwareSub: Int(payload[base + 3]),
            workMode: Int(payload[base + 4]),
            lightMode: Int(payload[base + 5]),
            switchState: Int(payload[base + 6]),
            brightness: brightness
        )
    }

    static func parsePictureStateResponse(_ payload: Data) -> AhaKeyPictureState? {
        guard payload.count >= 9 else { return nil }

        let mode = Int(payload[0])
        let startIndex = Int(UInt16(payload[1]) | (UInt16(payload[2]) << 8))
        let picLength = Int(UInt16(payload[3]) | (UInt16(payload[4]) << 8))
        let frameInterval = Int(UInt16(payload[5]) | (UInt16(payload[6]) << 8))
        let allModeMaxPic = Int(UInt16(payload[7]) | (UInt16(payload[8]) << 8))

        return AhaKeyPictureState(
            mode: mode,
            startIndex: startIndex,
            picLength: picLength,
            frameInterval: frameInterval,
            allModeMaxPic: allModeMaxPic
        )
    }

    /// 检查是否是 AhaKey 协议帧
    static func isProtocolFrame(_ data: Data) -> Bool {
        data.count >= 4
            && data[0] == 0xAA && data[1] == 0xBB
            && data[data.count - 2] == 0xCC && data[data.count - 1] == 0xDD
    }
}
