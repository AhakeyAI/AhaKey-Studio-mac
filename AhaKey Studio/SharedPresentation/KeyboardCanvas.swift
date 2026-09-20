import AppKit
import SwiftUI
import ImageIO

struct CanvasKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.12, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct AhaKeyKeyboardCanvasView: View {
    let modeDraft: AhaKeyModeDraft
    let selectedPart: AhaKeyStudioPart
    let lightBarPreview: IDEState
    let switchTitle: String
    let isAutomaticApproval: Bool
    let dirtyParts: Set<AhaKeyStudioPart>
    let onSelect: (AhaKeyStudioPart) -> Void
    let onModeSwitch: () -> Void
    var onSwitchToggle: (() -> Void)? = nil
    var liveLightMode: Int? = nil
    var liveIDEStateValue: Int? = nil
    var switchState: Int = 1   // 0=auto, 1=manual; firmware uses for color/effect overrides
    /// 0x83 查询出的当前 mode flash 帧数：nil=尚未查询/未连接；0=用户没上传；>0=已上传 N 帧
    var keyboardPictureFrameCount: Int? = nil

    @State private var modeSwitchPressed = false
    @State private var leverPressed = false

    private let baseWidth: CGFloat = 109
    private let baseHeight: CGFloat = 54

    var body: some View {
        GeometryReader { proxy in
            let drawingWidth = min(proxy.size.width, proxy.size.height * (baseWidth / baseHeight))
            let drawingHeight = drawingWidth * (baseHeight / baseWidth)

            ZStack {
                keyboardFrame(width: drawingWidth, height: drawingHeight)
            }
            .frame(width: drawingWidth, height: drawingHeight)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    @ViewBuilder
    private func keyboardFrame(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color(red: 0.92, green: 0.95, blue: 0.98)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1.2)
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 14)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                .padding(12)

            VStack {
                Spacer()
            }

            // 螺丝挪到真正的"边角内侧" + 缩小直径 4.8 → 3.6：
            // 旧位置 (8,8)/(8,46) 会被按键灰底矩形和灯条/Key1 边线擦边或交叠。
            // 新位置每颗距离灯条/按键灰底/Key 边都留出 ≥ 3 个基线单位。
            ForEach(Array([CGPoint(x: 5.5, y: 5.5), CGPoint(x: 103.5, y: 5.5), CGPoint(x: 5.5, y: 48.5), CGPoint(x: 103.5, y: 48.5)].enumerated()), id: \.offset) { _, point in
                Circle()
                    .stroke(Color.black.opacity(0.14), lineWidth: 1.2)
                    .background(Circle().fill(Color.white.opacity(0.4)))
                    .frame(width: scaled(3.6, in: width), height: scaled(3.6, in: width))
                    .position(position(point.x, point.y, width: width, height: height))
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                .frame(width: scaled(4.2, in: width), height: scaled(12, in: width))
                .position(position(3.8, 28, width: width, height: height))

            // 按键灰底：略收一点尺寸，使它显著低于灯条选中态阴影的影响范围（≥ 5 个基线单位）
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.035))
                .frame(width: scaled(67, in: width), height: scaled(21, in: width))
                .position(position(43.8, 38.5, width: width, height: height))

            ledBarButton(width: width, height: height)
            oledButton(width: width, height: height)
            keyButton(for: .voice, width: width, height: height)
            keyButton(for: .approve, width: width, height: height)
            keyButton(for: .reject, width: width, height: height)
            keyButton(for: .submit, width: width, height: height)
            modeSwitchKey(width: width, height: height)
            switchButton(width: width, height: height)
        }
    }

    // 固件 ws2812_mode_e (psk_ws2812.h) → Swift 灯效样式
    private func lightModeToEffect(_ mode: Int) -> LightEffectStyle {
        switch mode {
        case 1: return .singleMove
        case 2: return .rainbowMove
        case 3: return .rainbowWave
        case 4: return .rainbowWaveSlow
        case 5: return .breathing
        case 6: return .middleLight
        default: return .off
        }
    }

    private static let firmwareRed = Color(red: 240 / 255, green: 32 / 255, blue: 41 / 255)
    private static let firmwareBlue = Color(red: 32 / 255, green: 80 / 255, blue: 255 / 255)

    private func firmwareLEDState(ideState: IDEState?, modeData: Int, switchState: Int) -> (LightEffectStyle, Color) {
        guard let s = ideState else {
            return (.off, Self.firmwareRed)
        }
        let effect = modeDraft.lightBar.effect(for: s)
        let color: Color = s == .preToolUse && switchState != 0 ? Self.firmwareBlue : Self.firmwareRed
        return (effect, color)
    }

    private func ledBarButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.lightBar
        // 略向上、宽度往里收：让选中态阴影（radius 10pt）跟键盘内描边、按键灰底、LCD 都有 ≥ 5 个基线单位的余量
        let rect = frame(13.0, 4.5, 53.5, 8.6, width: width, height: height)
        let modeData = modeDraft.mode.rawValue
        let effect: LightEffectStyle
        let baseColor: Color
        if let live = liveLightMode {
            // BLE 连接且 mode tab 与物理 workMode 一致：直接信任固件回报的 ws2812_mode + claude_state
            effect = lightModeToEffect(live)
            let liveIDE: IDEState? = liveIDEStateValue.flatMap { IDEState(rawValue: UInt8($0)) }
            // 颜色：仅 preToolUse + manual 是蓝，其他均红（与固件 ws2812_single_color 设定一致）
            if let s = liveIDE, s == .preToolUse, switchState != 0 {
                baseColor = Self.firmwareBlue
            } else {
                baseColor = Self.firmwareRed
            }
        } else {
            // 离线/查看非物理档位：按固件逻辑模拟 update_claude_ws2812()
            let previewIDE = lightBarPreview
            (effect, baseColor) = firmwareLEDState(ideState: previewIDE, modeData: modeData, switchState: switchState)
        }
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.12) {
                Text(String(localized: "text.23acd5a1da34", defaultValue: "灯条"))
                    .font(.system(size: max(rect.height * 0.18, 10), weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .center)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let colors = ledColors(effect: effect, time: context.date.timeIntervalSince1970, count: 10, baseColor: baseColor)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.12))
                        HStack(spacing: rect.width * 0.026) {
                            ForEach(0..<10, id: \.self) { index in
                                Capsule()
                                    .fill(colors[index])
                                    .frame(width: rect.width * 0.072, height: rect.height * 0.26)
                                    .shadow(color: colors[index].opacity(0.65), radius: 2.5)
                            }
                        }
                        .padding(.horizontal, rect.width * 0.04)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: rect.height * 0.48)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    private func oledButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.oledDisplay
        let rect = frame(71.2, 7.7, 24.2, 13.4, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                    oledInnerContent(rect: rect)
                }
                // 右上角徽章：反映键盘 flash 真实状态
                pictureStateBadge(rect: rect)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func pictureStateBadge(rect: CGRect) -> some View {
        if let count = keyboardPictureFrameCount {
            let isUploaded = count > 0
            let label = isUploaded ? String(localized: "text.39c703baae31", defaultValue: "✓ 已上传 \(count) 帧") : String(localized: "text.33359dd5cb6e", defaultValue: "未上传")
            Text(label)
                .font(.system(size: max(rect.height * 0.11, 8), weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, rect.width * 0.04)
                .padding(.vertical, rect.height * 0.02)
                .background(
                    Capsule()
                        .fill(isUploaded ? Color.green.opacity(0.85) : Color.gray.opacity(0.85))
                )
                .padding(rect.width * 0.025)
        }
    }

    /// 真实 LCD 是 160×80（2:1）。在 slot 中央用一个 2:1 的"屏幕区"渲染内容，
    /// 周围留键盘黑壳作为外框；图片 / 占位都在屏幕区内 .fit，不会撑出范围、不会被裁切。
    private func screenInnerSize(for rect: CGRect) -> CGSize {
        let screenAspect: CGFloat = 2.0
        if rect.width / rect.height >= screenAspect {
            let h = rect.height * 0.86
            return CGSize(width: h * screenAspect, height: h)
        } else {
            let w = rect.width * 0.86
            return CGSize(width: w, height: w / screenAspect)
        }
    }

    private func oledInnerContent(rect: CGRect) -> some View {
        let size = screenInnerSize(for: rect)
        return ZStack {
            Color.clear
            screenBody(screenWidth: size.width, screenHeight: size.height)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func screenBody(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        if let gifPath = modeDraft.oled.localAssetPath {
            // .id(gifPath) 强制 SwiftUI 在路径切换时销毁并重建播放器，
            // 否则旧路径的图片源与新路径可能短暂错位，
            // 导致 Mode 切换瞬间画布渲染上一档 GIF 的某一帧（claude / cursor 互窜）。
            AnimatedGIFView(path: gifPath, fps: modeDraft.oled.framesPerSecond)
                .id(gifPath)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.6), Color.black.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .center, spacing: 2) {
                    if modeDraft.mode == .mode0 {
                        HStack(spacing: 4) {
                            Image(systemName: "cloud.fill")
                                .font(.system(size: screenHeight * 0.24, weight: .semibold))
                                .foregroundStyle(Color.orange.opacity(0.92))
                            Text(modeDraft.mode.title)
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(String(localized: "text.e7a3603b5715", defaultValue: "默认动图"))
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: {
                                if #available(macOS 13, *) { "sparkles.rectangle.stack" } else { "rectangle.stack" }
                            }())
                                .font(.system(size: screenHeight * 0.22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.78))
                            Text(String(localized: "text.33359dd5cb6e", defaultValue: "未上传"))
                                .font(.system(size: screenHeight * 0.20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        Text(String(localized: "text.e9a581e94fc8", defaultValue: "等待自定义"))
                            .font(.system(size: screenHeight * 0.18))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(screenWidth * 0.04)
                .multilineTextAlignment(.center)
            }
        }
    }

    private func keyButton(for role: AhaKeyKeyRole, width: CGFloat, height: CGFloat) -> some View {
        let part = role.part
        let keyDraft = modeDraft.key(for: role)
        let specs: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        switch role {
        case .voice:
            specs = (10.2, 29.2, 16.2, 16.8)
        case .approve:
            specs = (27.2, 29.2, 16.2, 16.8)
        case .reject:
            specs = (44.2, 29.2, 16.2, 16.8)
        case .submit:
            specs = (61.2, 29.2, 16.2, 16.8)
        }
        let rect = frame(specs.x, specs.y, specs.w, specs.h, width: width, height: height)
        return Button {
            onSelect(part)
        } label: {
            VStack(spacing: rect.height * 0.07) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, Color(red: 0.95, green: 0.96, blue: 0.98)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    keyIcon(for: role, size: rect.height * 0.28)
                }
                .frame(width: rect.width * 0.8, height: rect.height * 0.76)

                Text(keyDraft.description.isEmpty ? keyDraft.displaySummary : keyDraft.description)
                    .font(.system(size: rect.height * 0.11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    @ViewBuilder
    private func keyIcon(for role: AhaKeyKeyRole, size: CGFloat) -> some View {
        Image(systemName: role.systemImage)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(Color.black.opacity(0.88))
    }

    private func modeSwitchKey(width: CGFloat, height: CGFloat) -> some View {
        let rect = frame(78.9, 40.9, 8.0, 10.2, width: width, height: height)
        return Button {
            onModeSwitch()
        } label: {
            VStack(spacing: rect.height * 0.08) {
                ZStack {
                    RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.2, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: rect.height * 0.18, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.72))
                }
                .frame(width: rect.width * 0.78, height: rect.height * 0.5)

                Text(String(localized: "studio.mode", defaultValue: "模式"))
                    .font(.system(size: rect.height * 0.1, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
        .help(String(localized: "text.3bcbe9ca2bd5", defaultValue: "点击切换 Mode（模拟实体键）"))
    }

    private func switchButton(width: CGFloat, height: CGFloat) -> some View {
        let part = AhaKeyStudioPart.toggleSwitch
        let rect = frame(87.8, 35.6, 6.8, 10.6, width: width, height: height)
        return Button {
            onSelect(part)
            // 物理拨杆损坏的用户靠这个：点击即翻转 auto/manual。
            // 最新固件 0x91 用于灯效预览，因此这里只改 hook 软件覆盖。
            onSwitchToggle?()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                        .fill(Color.black.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: rect.width * 0.18, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        )
                    Capsule()
                        .fill(Color.white)
                        .frame(width: rect.width * 0.36, height: rect.height * 0.65)
                        .overlay(Circle().fill(Color.gray.opacity(0.24)).frame(width: rect.width * 0.28, height: rect.width * 0.28))
                        .offset(y: isAutomaticApproval ? -rect.height * 0.08 : rect.height * 0.12)
                }
                .frame(width: rect.width * 0.58, height: rect.height * 0.78)

                Text(switchTitle)
                    .font(.system(size: rect.height * 0.12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: rect.width, height: rect.height)
            .modifier(HotspotChrome(part: part, selectedPart: selectedPart, dirtyParts: dirtyParts))
        }
        .buttonStyle(CanvasKeyButtonStyle())
        .position(x: rect.midX, y: rect.midY)
    }

    private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x / baseWidth * width,
            y: y / baseHeight * height,
            width: w / baseWidth * width,
            height: h / baseHeight * height
        )
    }

    private func position(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: x / baseWidth * width, y: y / baseHeight * height)
    }

    private func scaled(_ value: CGFloat, in width: CGFloat) -> CGFloat {
        value / baseWidth * width
    }

    private func ledColors(effect: LightEffectStyle, time: TimeInterval, count: Int,
                           baseColor: Color = Self.firmwareRed) -> [Color] {
        switch effect {
        case .off:
            return Array(repeating: Color.gray.opacity(0.15), count: count)
        case .middleLight:
            let center = Double(count - 1) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let pulse = (sin(time * 1.5) + 1.0) / 2.0 * 0.15
                return baseColor.opacity(0.2 + (1.0 - dist) * 0.65 + pulse)
            }
        case .singleMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.75)
                return baseColor.opacity(0.12 + brightness * 0.82)
            }
        case .breathing:
            let breath = (sin(time * Double.pi * 0.9) + 1.0) / 2.0
            return Array(repeating: baseColor.opacity(0.12 + breath * 0.78), count: count)
        case .rainbowMove:
            let period = 2.4
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = max(0.0, 1.0 - dist * 0.7)
                let hue = (Double(i) / Double(count) + time * 0.25).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.15 + brightness * 0.85)
            }
        case .rainbowWave:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.4).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .rainbowWaveSlow:
            return (0..<count).map { i in
                let hue = (Double(i) / Double(count) + time * 0.14).truncatingRemainder(dividingBy: 1.0)
                return Color(hue: hue, saturation: 1.0, brightness: 0.9)
            }
        case .typingRipple:
            let center = Double(count - 1) / 2.0
            let phase = time.truncatingRemainder(dividingBy: 1.6) / 1.6
            let rippleRadius = phase * center * 1.8
            return (0..<count).map { i in
                let dist = abs(Double(i) - center)
                let wave = max(0, 1.0 - abs(dist - rippleRadius) * 0.8)
                return baseColor.opacity(0.1 + wave * 0.85)
            }
        case .comet:
            let period = 1.8
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t * Double(count + 3) - 1.5
            return (0..<count).map { i in
                let dist = Double(i) - pos
                let tail = dist >= 0 ? 0.0 : max(0, 1.0 + dist * 0.25)
                let head = dist >= 0 && dist < 1.5 ? max(0, 1.0 - dist * 0.65) : 0.0
                return baseColor.opacity(0.08 + max(tail, head) * 0.88)
            }
        case .scanBar:
            let period = 2.0
            let t = time.truncatingRemainder(dividingBy: period) / period
            let pos = t < 0.5 ? t * 2.0 * Double(count - 1) : (1.0 - (t - 0.5) * 2.0) * Double(count - 1)
            return (0..<count).map { i in
                let dist = abs(Double(i) - pos)
                let brightness = dist < 1.5 ? 1.0 - dist * 0.3 : 0.0
                return baseColor.opacity(0.08 + max(0, brightness) * 0.88)
            }
        case .pulseCenter:
            let center = Double(count - 1) / 2.0
            let pulse = (sin(time * Double.pi * 2.5) + 1.0) / 2.0
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let intensity = pulse * max(0, 1.0 - dist * 0.8)
                return baseColor.opacity(0.08 + intensity * 0.88)
            }
        case .warningBlink:
            let blink = sin(time * Double.pi * 4.0) > 0 ? 0.9 : 0.1
            let orange = Color(red: 1.0, green: 0.6, blue: 0.0)
            return Array(repeating: orange.opacity(blink), count: count)
        case .successSweep:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let progress = time.truncatingRemainder(dividingBy: 2.0) / 2.0
            let fillPos = progress * Double(count + 2) - 1
            return (0..<count).map { i in
                let lit = Double(i) <= fillPos ? 1.0 : 0.0
                return green.opacity(0.08 + lit * 0.88)
            }
        case .blueThinking:
            let blue = Color(red: 0.2, green: 0.5, blue: 1.0)
            return (0..<count).map { i in
                let wave = (sin(time * Double.pi * 0.8 + Double(i) * 0.6) + 1.0) / 2.0
                return blue.opacity(0.15 + wave * 0.75)
            }
        case .lowBattery:
            let red = Color(red: 1.0, green: 0.15, blue: 0.1)
            let pulse = (sin(time * Double.pi * 0.5) + 1.0) / 2.0
            return Array(repeating: red.opacity(0.1 + pulse * 0.6), count: count)
        case .chargingFlow:
            let green = Color(red: 0.1, green: 0.85, blue: 0.3)
            let period = 3.0
            let progress = time.truncatingRemainder(dividingBy: period) / period
            let fillPos = progress * Double(count)
            return (0..<count).map { i in
                let lit = Double(i) < fillPos ? 0.85 : 0.08
                return green.opacity(lit)
            }
        case .approvalWait:
            let amber = Color(red: 1.0, green: 0.75, blue: 0.2)
            let center = Double(count - 1) / 2.0
            let breath = (sin(time * Double.pi * 1.2) + 1.0) / 2.0
            let centerBlink = sin(time * Double.pi * 3.0) > 0 ? 1.0 : 0.4
            return (0..<count).map { i in
                let dist = abs(Double(i) - center) / center
                let isCenter = dist < 0.2
                let intensity = isCenter ? centerBlink : breath * (1.0 - dist * 0.5)
                return amber.opacity(0.1 + intensity * 0.8)
            }
        }
    }

}

struct AnimatedGIFView: View {
    let path: String
    let fps: Int
    var maxPixelSize = 320

    @StateObject private var player = AnimatedGIFPlayer()

    var body: some View {
        Group {
            if let currentImage = player.currentImage {
                Image(nsImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear {
            player.start(path: path, fps: fps, maxPixelSize: maxPixelSize)
        }
        .onChange(of: path) { newPath in
            player.start(path: newPath, fps: fps, maxPixelSize: maxPixelSize)
        }
        .onChange(of: fps) { newFPS in
            player.start(path: path, fps: newFPS, maxPixelSize: maxPixelSize)
        }
        .onDisappear {
            player.stop()
        }
    }
}

/// GIF 预览只保留当前缩放帧。避免把源文件的所有原分辨率帧一次性解码并常驻内存。
final class AnimatedGIFPlayer: ObservableObject {
    @Published private(set) var currentImage: NSImage?

    private var imageSource: CGImageSource?
    private var timer: Timer?
    private var frameCount = 0
    private var currentFrameIndex = 0
    private var maxPixelSize = 320

    func start(path: String, fps: Int, maxPixelSize: Int) {
        stop()

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let url = URL(fileURLWithPath: path)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else { return }

        self.imageSource = imageSource
        self.frameCount = frameCount
        self.currentFrameIndex = 0
        self.maxPixelSize = max(1, maxPixelSize)
        renderCurrentFrame()

        guard frameCount > 1 else { return }
        let timer = Timer(timeInterval: 1.0 / Double(max(fps, 1)), repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        imageSource = nil
        frameCount = 0
        currentFrameIndex = 0
        currentImage = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func advanceFrame() {
        guard frameCount > 1 else { return }
        currentFrameIndex = (currentFrameIndex + 1) % frameCount
        renderCurrentFrame()
    }

    private func renderCurrentFrame() {
        guard let imageSource else {
            currentImage = nil
            return
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary

        currentImage = autoreleasepool {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                currentFrameIndex,
                thumbnailOptions
            ) else {
                return nil
            }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
    }
}
