import AppKit
import CoreImage
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct AhaKeyStudioView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var voiceRelay = VoiceRelayService.shared
    @StateObject private var nativeSpeech = NativeSpeechTranscriptionService.shared
    @StateObject private var ahaType = AhaTypeTextOptimizer.shared
    @StateObject private var cloudAccount = CloudAccountManager.shared
    @StateObject private var agentManager = AgentManager.shared

    @State private var studioDraft: AhaKeyStudioDraft
    @State private var lastSyncedDraft: AhaKeyStudioDraft
    @State private var selectedMode: AhaKeyModeSlot
    @State private var selectedPart: AhaKeyStudioPart
    @State private var lightBarPreview: IDEState
    @State private var modeCustomNames: [Int: String] = [:]
    @State private var lastSyncDate: Date?
    @State private var syncStatusMessage = String(localized: "text.c1877e6f12d1", defaultValue: "修改会先保存在本地，连接设备后再同步。")
    @State private var isSyncing = false
    // AhaKeyStudio 交还蓝牙给 Agent 的过渡期：保持"已连接"显示，直到 Agent 接管或超时。
    @State private var isTransitioningToKeyboardControl = false
    @State private var showsOLEDPlaybackPreview = false
    @State private var showsDeviceInfo = false
    @State private var showsFirmwareFlasher = false
    @State private var showsCloudAccount = false
    @State private var showsAhaTypeLoginRequiredToast = false
    @AppStorage(UnifiedOnboardingStorage.completedKey) private var unifiedOnboardingCompleted = false
    @State private var isEditingInspector = false
    @State private var showsDiagnostics = false
    @State private var showsKeyHelp = false
    @State private var selectedTriggerTab: Int = 0
    /// 每次主 App 自占 BLE 连接成功只跑一次默认 LCD 自动同步。
    /// .onChange(of: isConnected) 在断开时重置；下次重连时再触发一次。
    @State private var oledAutoSyncDoneForConnection: Bool = false
    @State private var showsHelpCenter = false
    @State private var showsGuidanceDetail = false
    @State private var editingModeSlot: AhaKeyModeSlot?
    @State private var editingModeName: String = ""
    @FocusState private var modeNameFieldFocused: Bool
    @State private var showsWriteResultAlert = false
    @State private var writeResultAlertMessage = ""
    @State private var deviceWriteSucceeded = false

    init(bleManager: AhaKeyBLEManager) {
        self.bleManager = bleManager
        let initialDraft = AhaKeyStudioStore.load() ?? .default
        // 注意：不要在这里调用 VoiceRelayService.updateRoutes —— SwiftUI 会因 bleManager
        // 的 @Published 属性（workMode/电量/连接状态等）频繁重建 view，init 会跟着多次执行。
        // 任何在 init 里调用 updateRoutes 都会重置 functionRelay 的 holdingRoute（按住状态），
        // 导致微信等"按住说话"过几秒就自动结束。正确入口在下面的 .onAppear。
        _studioDraft = State(initialValue: initialDraft)
        _lastSyncedDraft = State(initialValue: initialDraft)
        let initialMode = AhaKeyModeSlot(rawValue: bleManager.workMode) ?? .mode0
        _selectedMode = State(initialValue: initialMode)
        _selectedPart = State(initialValue: .key1)
        _lightBarPreview = State(initialValue: .preToolUse)
        _modeCustomNames = State(initialValue: AhaKeyModeNameStore.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                canvasPane
                Divider()
                inspectorPane
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            agentManager.applyStoredBluetoothPreferenceOnLaunch(bleManager: bleManager)
            voiceRelay.start()
            nativeSpeech.start()
            bleManager.refreshBluetoothAuthorization()
            applyCursorRejectMacroSelfHealIfNeeded()
            voiceRelay.updateRoutes(from: studioDraft)
            SwitchStateNotifier.shared.bind(to: bleManager)
            NotificationCenter.default.post(
                name: .ahaKeyKeyboardWorkModeChanged,
                object: nil,
                userInfo: ["workMode": bleManager.workMode]
            )
            scheduleStartupPermissionOnboarding()
        }
        .onChange(of: studioDraft) { newValue in
            AhaKeyStudioStore.save(newValue)
            voiceRelay.updateRoutes(from: newValue)
        }
        // 键盘物理档位变化（BLE 查询/通知上报）→ 自动切到对应 Mode 标签，
        // 这样 LCD 预览、快捷键草稿、发出去的 updateState 三者一致。
        .onChange(of: bleManager.workMode) { newValue in
            if let slot = AhaKeyModeSlot(rawValue: newValue), slot != selectedMode {
                selectedMode = slot
            }
        }
        .onChange(of: selectedMode) { newValue in
            guard bleManager.isConnected,
                  bleManager.commandCharReady,
                  bleManager.workMode != newValue.rawValue else { return }
            bleManager.setWorkMode(UInt8(newValue.rawValue))
            syncStatusMessage = String(localized: "text.c401d3e18903", defaultValue: "已通知键盘切换到 \(String(describing: newValue.title))。")
        }
        .onChange(of: bleManager.isConnected) { connected in
            if !connected { oledAutoSyncDoneForConnection = false }
        }
        .onChange(of: bleManager.keyboardPictureStates) { _ in
            guard !oledAutoSyncDoneForConnection else { return }
            // 四个 mode 都查回来才动手
            guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }
            oledAutoSyncDoneForConnection = true
            Task { await autoSyncDefaultOLEDsIfNeeded() }
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.microphoneGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.speechRecognitionGranted) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.siriEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
        .onChange(of: nativeSpeech.dictationEnabled) { _ in
            refreshStartupPermissionOnboarding()
        }
        .alert("Agent", isPresented: Binding(
            get: { agentManager.agentUserAlert != nil },
            set: { if !$0 { agentManager.agentUserAlert = nil } }
        )) {
            Button(String(localized: "text.f867f3417859", defaultValue: "好"), role: .cancel) {
                agentManager.agentUserAlert = nil
            }
        } message: {
            Text(agentManager.agentUserAlert ?? "")
        }
        .alert(String(localized: "text.8f95949f326b", defaultValue: "AhaType 未注册登录"), isPresented: $showsAhaTypeLoginRequiredToast) {
            Button(String(localized: "text.de32e20193ad", defaultValue: "知道了"), role: .cancel) {}
            Button(String(localized: "text.58f24a16bfcb", defaultValue: "注册登录")) {
                showsCloudAccount = true
            }
        } message: {
            Text(String(localized: "text.eb139e47c9c1", defaultValue: "请先注册登录 AhaType 后再开启云端整理。"))
        }
        .sheet(isPresented: $showsOLEDPlaybackPreview) {
            OLEDMotionPreviewSheet(
                modeTitle: selectedMode.title,
                assetPath: currentModeDraft.oled.localAssetPath,
                fps: currentModeDraft.oled.framesPerSecond
            )
        }
        .sheet(isPresented: $showsDeviceInfo) {
            DeviceInfoSheetContainer(bleManager: bleManager)
                .frame(width: 720, height: 720)
        }
        .sheet(isPresented: $showsFirmwareFlasher) {
            FirmwareFlasherView(bleManager: bleManager)
        }
        .sheet(isPresented: $showsCloudAccount) {
            CloudAccountView()
                .frame(width: 520, height: 620)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text("AhaKey Studio")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
            }
            .layoutPriority(1)

            HStack(spacing: 8) {
                infoPill(
                    title: isEffectivelyConnected ? String(localized: "text.5be0323e8adc", defaultValue: "已连接") : (bleManager.isScanning ? String(localized: "text.a55df7a163ae", defaultValue: "扫描中") : String(localized: "text.3d52574ce150", defaultValue: "未连接")),
                    // 未连接时不再笼统显示「等待设备」，而是给出细分链路诊断（Issue #34）。
                    subtitle: isEffectivelyConnected ? (bleManager.deviceName ?? String(localized: "text.5be0323e8adc", defaultValue: "已连接")) : bleManager.linkDiagnostic.shortMessage,
                    accent: isEffectivelyConnected ? .green : .orange,
                    width: 118
                )
                .help(isEffectivelyConnected ? "" : bleManager.linkDiagnostic.detail)
                infoPill(
                    title: String(localized: "text.1c69b1aa723a", defaultValue: "电量"),
                    subtitle: isEffectivelyConnected ? "\(bleManager.batteryLevel)%" : "—",
                    accent: .blue
                )
                infoPill(
                    title: String(localized: "text.ad80c32c571a", defaultValue: "拨杆"),
                    subtitle: currentSwitchTitle,
                    accent: liveKeyboardSwitchState == 0 ? .mint : .indigo
                )
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            if !bleManager.isConnected, agentManager.bluetoothConnectionOwner == .ahaKeyStudio {
                Button(bleManager.isScanning ? String(localized: "text.463fa583e0d3", defaultValue: "扫描中…") : String(localized: "text.7b4be6a35846", defaultValue: "连接设备")) {
                    bleManager.userInitiatedConnect()
                }
                .buttonStyle(.bordered)
                .disabled(bleManager.isScanning)
            }

            ahaTypeModeStatus

            configurationModeControl

            if shouldShowTopBarInstallStartButton {
                Button(String(localized: "text.7218d4b417c2", defaultValue: "安装启动")) {
                    installStartAgentFromTopBar()
                }
                .buttonStyle(.borderedProminent)
                .disabled(agentManager.isAgentOperationInProgress)
                .help(String(localized: "text.dbdfc3355d05", defaultValue: "安装/修复 Agent 与 Hook，并启动 Agent 控制键盘。"))
            }

            Button {
                NSPasteboard.general.clearContents()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                    .imageScale(.medium)
            }
            .buttonStyle(.bordered)
            .help(String(localized: "text.295b6ac61e78", defaultValue: "清空剪贴板"))

            Menu {
                Button(String(localized: "text.a1d4c93be320", defaultValue: "恢复当前模式默认值")) {
                    restoreCurrentModeDefaults()
                }
                Button(String(localized: "text.110238e73702", defaultValue: "重新连接设备")) {
                    bleManager.disconnect()
                    bleManager.userInitiatedConnect()
                }
                Button(String(localized: "text.13e330727061", defaultValue: "设备信息 · Agent…")) {
                    showsDeviceInfo = true
                }
                Button(String(localized: "text.6b12f0695908", defaultValue: "固件升级 · USB ISP…")) {
                    showsFirmwareFlasher = true
                }
                Divider()
                Button(String(localized: "text.a7b0c30b44f4", defaultValue: "云端账号 · AhaType…")) {
                    showsCloudAccount = true
                }
                Button(String(localized: "text.a0ef49f1cde1", defaultValue: "刷新 AhaType 状态")) {
                    ahaType.refreshFromDisk()
                }
                Divider()
                Button(String(localized: "text.b0c89fd5e3e1", defaultValue: "隐藏到后台")) {
                    NSApp.keyWindow?.close()
                }
                Button(String(localized: "text.f8995dd390ed", defaultValue: "退出 AhaKey Studio")) {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32, height: 28)
            .help(String(localized: "text.38844b135cf7", defaultValue: "更多"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(chromeBarBackground)
    }

    private var configurationModeStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isEditingConfiguration ? Color.blue : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(isEditingConfiguration ? String(localized: "text.e51f42639f0c", defaultValue: "编辑配置中") : String(localized: "text.9b7ce42746c3", defaultValue: "键盘控制中"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(configurationModeDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: isEditingConfiguration ? "checkmark.circle" : "pencil.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEditingConfiguration ? Color.blue : Color.green)
        }
        .frame(width: 138, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var configurationModeControl: some View {
        Button(action: handleConfigurationModeButton) {
            configurationModeStatus
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(configurationModeButtonTitle)
        .accessibilityHint(configurationModeButtonHelp)
        .help(configurationModeButtonHelp)
    }

    private var ahaTypeModeStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ahaType.isEnabled ? Color.green : Color.gray.opacity(0.55))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(ahaType.isEnabled ? String(localized: "text.17a4abb0b76e", defaultValue: "AhaType 开启") : String(localized: "text.c68a007efefe", defaultValue: "AhaType 关闭"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(ahaType.isEnabled ? String(localized: "text.659f7031033a", defaultValue: "云端整理已启用") : String(localized: "text.78cca43e02b3", defaultValue: "语音结果直接粘贴"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Toggle("", isOn: Binding(
                get: { ahaType.isEnabled },
                set: { enabled in
                    if enabled, !cloudAccount.isLoggedIn {
                        showsAhaTypeLoginRequiredToast = true
                    } else {
                        ahaType.setEnabled(enabled)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .frame(width: 150, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help(String(localized: "text.789143a59c44", defaultValue: "开启后，macOS 原生语音转写会先经过 AhaType 云端整理，再粘贴到当前光标。"))
    }

    private var canvasPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            modeEditorHeader

            VStack(alignment: .leading, spacing: 8) {
                AhaKeyKeyboardCanvasView(
                    modeDraft: currentModeDraft,
                    selectedPart: selectedPart,
                    lightBarPreview: lightBarPreview,
                    switchTitle: currentSwitchTitle,
                    isAutomaticApproval: liveKeyboardSwitchState == 0,
                    dirtyParts: dirtyPartsForCurrentMode(),
                    onSelect: { selectedPart = $0 },
                    onModeSwitch: { cycleModeForward() },
                    onSwitchToggle: { toggleVirtualSwitch() },
                    liveLightMode: liveCanvasLightMode,
                    liveIDEStateValue: liveCanvasIDEStateValue,
                    switchState: liveCanvasSwitchState,
                    keyboardPictureFrameCount: bleManager.keyboardPictureStates[selectedMode.rawValue]?.frameCount
                )
                .aspectRatio(109.0 / 54.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

                Text(String(localized: "text.1f526e2854f5", defaultValue: "点按灯条、屏幕、四个按键或拨杆即可进入对应配置。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func modeTabItem(_ mode: AhaKeyModeSlot) -> some View {
        let isSelected = selectedMode == mode
        let isEditing = editingModeSlot == mode

        if isEditing {
            TextField("", text: $editingModeName, onCommit: { commitModeNameEdit() })
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .focused($modeNameFieldFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(Color.accentColor.opacity(0.15))
                .onExitCommand { commitModeNameEdit() }
                .onAppear { modeNameFieldFocused = true }
                .onChange(of: modeNameFieldFocused) { focused in
                    if !focused { commitModeNameEdit() }
                }
        } else {
            Text(modeCustomNames[mode.rawValue] ?? mode.defaultName)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    commitModeNameEdit()
                    editingModeName = modeCustomNames[mode.rawValue] ?? mode.defaultName
                    editingModeSlot = mode
                    selectedMode = mode
                }
                .onTapGesture(count: 1) {
                    commitModeNameEdit()
                    selectedMode = mode
                }
        }
    }

    private func commitModeNameEdit() {
        guard let slot = editingModeSlot else { return }
        let capped = String(editingModeName.prefix(30))
        if capped.isEmpty || capped == slot.defaultName {
            modeCustomNames.removeValue(forKey: slot.rawValue)
        } else {
            modeCustomNames[slot.rawValue] = capped
        }
        AhaKeyModeNameStore.save(modeCustomNames)
        editingModeSlot = nil
    }

    private var modeEditorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(String(localized: "studio.keyboard-mode", defaultValue: "键盘模式"))
                    .font(.system(size: 17, weight: .semibold))

                HStack(spacing: 0) {
                    ForEach(AhaKeyModeSlot.allCases) { mode in
                        modeTabItem(mode)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(width: 480)

                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selectedMode.guidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = selectedMode.guidanceHoverDetail {
                    Button {
                        showsGuidanceDetail.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help(detail)
                    .onHover { showsGuidanceDetail = $0 }
                    .popover(isPresented: $showsGuidanceDetail, arrowEdge: .top) {
                        Text(detail)
                            .font(.callout)
                            .padding(14)
                            .frame(width: 320)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isEditingInspector {
                        Label(selectedPart.title, systemImage: selectedPart.systemImage)
                            .font(.system(size: 18, weight: .semibold))

                        Group {
                            switch selectedPart {
                            case .key1, .key2, .key3, .key4: keyInspector
                            case .oledDisplay: oledInspector
                            case .lightBar: lightBarInspector
                            case .toggleSwitch: switchInspector
                            }
                        }

                    } else {
                        inspectorHeader

                        VStack(alignment: .leading, spacing: 0) {
                            partSummaryContent
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                                )
                        )

                        HStack {
                            Spacer()
                            Button {
                                enterEditingConfiguration()
                                withAnimation(.easeInOut(duration: 0.2)) { isEditingInspector = true }
                            } label: {
                                Label(String(localized: "text.37090f456516", defaultValue: "修改"), systemImage: "pencil")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .keyboardShortcut("e", modifiers: .command)
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(24)
            }

            if isEditingInspector {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingInspector = false
                            returnToKeyboardControl()
                        }
                    } label: {
                        Label(String(localized: "text.572cf45ba436", defaultValue: "返回"), systemImage: "chevron.left")
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    if selectedPart == .lightBar {
                        Button {
                            previewLightEffect(for: lightBarPreview)
                        } label: {
                            Label(String(localized: "text.e819456d7ecf", defaultValue: "预览到键盘"), systemImage: "play.fill")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isSyncing || !bleManager.isConnected || !bleManager.commandCharReady)
                    }

                    Button {
                        writeToKeyboard()
                    } label: {
                        Label(isSyncing ? String(localized: "text.a5969ce33de7", defaultValue: "写入中…") : String(localized: "text.633329fcd3ef", defaultValue: "写入键盘"), systemImage: isSyncing ? "arrow.trianglehead.2.clockwise" : "square.and.arrow.down")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSyncing || !bleManager.isConnected)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .onChange(of: selectedPart) { _ in
            commitModeNameEdit()
            withAnimation(.easeInOut(duration: 0.18)) { isEditingInspector = false }
        }
        .onChange(of: selectedMode) { _ in
            if editingModeSlot != nil && editingModeSlot != selectedMode {
                commitModeNameEdit()
            }
        }
        .alert(String(localized: "text.2e4576a516f2", defaultValue: "写入结果"), isPresented: $showsWriteResultAlert) {
            Button(String(localized: "text.fd4b9e3b6c68", defaultValue: "继续编辑"), role: .cancel) {}
            Button(String(localized: "text.37b5a36966ae", defaultValue: "完成编辑")) {
                if deviceWriteSucceeded {
                    completeEditingAfterSuccessfulWrite()
                }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(writeResultAlertMessage)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(selectedPart.title, systemImage: selectedPart.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                if partIsDirty(selectedPart) {
                    Label(String(localized: "text.9a964fbc3d5a", defaultValue: "未同步"), systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if selectedPart.isKey {
                    Button {
                        showsKeyHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.borderless)
                    .onHover { showsKeyHelp = $0 }
                    .popover(isPresented: $showsKeyHelp, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "text.26eb7cff0f41", defaultValue: "如何使用"))
                                .font(.headline)
                            Divider()
                            Text(String(localized: "text.66cfd23864b7", defaultValue: "1. 点击虚拟键盘对应按键选中它。"))
                            Text(String(localized: "text.8e045a58d6d0", defaultValue: "2. 语音键先选预设；其他键按需选单键或宏。"))
                            Text(String(localized: "text.1864bebaf558", defaultValue: "3. 配置完成后点「写入键盘」同步到键盘。"))
                            Text(String(localized: "text.a2fabc293107", defaultValue: "4. 切模式时 LCD 先显示描述，再回到该模式动图。"))
                        }
                        .font(.callout)
                        .padding(16)
                        .frame(width: 270)
                    }
                }
            }
            Text(selectedPart.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 权限诊断弹窗

    private var diagnosticsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(String(localized: "text.22aa5b3f29c5", defaultValue: "权限诊断"))
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) { showsDiagnostics = false }
                        .buttonStyle(.bordered)
                }

                GroupBox(String(localized: "text.d9037192399c", defaultValue: "后台语音桥")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(voiceRelay.isListening ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(voiceRelay.isListening ? String(localized: "text.a3a6f61b53db", defaultValue: "后台监听中") : String(localized: "text.39261aa10981", defaultValue: "等待系统权限"))
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: String(localized: "text.fc22bc8bea45", defaultValue: "输入监控"), granted: voiceRelay.inputMonitoringGranted)
                            permissionBadge(title: String(localized: "text.b8f88aeead15", defaultValue: "辅助功能"), granted: voiceRelay.accessibilityGranted)
                        }
                        Text(voiceRelay.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(voiceRelay.activeRouteSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(String(localized: "text.ddd4ab52cb69", defaultValue: "再次申请权限")) {
                                requestPermissionsThenOpenPrivacySettingsIfNeeded(
                                    bleManager: bleManager,
                                    voiceRelay: voiceRelay,
                                    nativeSpeech: nativeSpeech
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            Button(String(localized: "text.65208b4d7435", defaultValue: "重新检查权限")) {
                                voiceRelay.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                        }
                    }
                    .padding(.top, 4)
                }

                GroupBox(String(localized: "text.11da5f1d7a66", defaultValue: "苹果原生转写")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : (nativeSpeech.microphoneGranted && nativeSpeech.speechRecognitionGranted ? Color.green : Color.orange))
                                .frame(width: 10, height: 10)
                            Text(nativeSpeech.isRecording ? String(localized: "text.b286e52f8dd0", defaultValue: "录音转写中") : String(localized: "text.9eb72b39d5fe", defaultValue: "等待触发"))
                                .font(.callout.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            permissionBadge(title: String(localized: "text.714cac30e2ff", defaultValue: "麦克风"), granted: nativeSpeech.microphoneGranted)
                            permissionBadge(title: String(localized: "text.dc4d60da1bcd", defaultValue: "语音转写"), granted: nativeSpeech.speechRecognitionGranted)
                            permissionBadge(title: "Siri", granted: nativeSpeech.siriEnabled)
                            permissionBadge(title: String(localized: "text.a44d14888ce8", defaultValue: "听写"), granted: nativeSpeech.dictationEnabled)
                        }
                        Text(nativeSpeech.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(nativeSpeech.lastPermissionCheckSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()

                        HStack(spacing: 10) {
                            Circle()
                                .fill(nativeSpeech.isRecording ? Color.red : Color.clear)
                                .frame(width: 8, height: 8)
                            Text(nativeSpeech.isRecording ? String(localized: "text.e35a149d9bc7", defaultValue: "录音中") : String(localized: "text.452b33806e61", defaultValue: "转写测试"))
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !nativeSpeech.transcriptPreview.isEmpty {
                                Text(nativeSpeech.transcriptPreview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if !nativeSpeech.lastCommittedText.isEmpty {
                                Text(String(localized: "text.1428a09a2047", defaultValue: "最近写入：\(String(describing: nativeSpeech.lastCommittedText))"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 8) {
                            Button(nativeSpeech.isRecording ? String(localized: "text.9e0ce704cc88", defaultValue: "结束并写入") : String(localized: "text.ee9247035880", defaultValue: "开始录音")) {
                                nativeSpeech.toggleRecordingFromVoiceKey()
                            }
                            .buttonStyle(.borderedProminent)
                            Button(String(localized: "text.65208b4d7435", defaultValue: "重新检查权限")) {
                                nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                            }
                            .buttonStyle(.bordered)
                            RestartToApplyPermissionsButton()
                            if !nativeSpeechPermissionsReady {
                                Button(String(localized: "text.0407dbdaf0dd", defaultValue: "打开系统设置")) { openNativeSpeechPrivacySettings() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                let voiceKey = currentModeDraft.key(for: .voice)
                if let preset = voiceKey.voicePreset, preset == .typeless {
                    GroupBox(String(localized: "text.8665e2a989f8", defaultValue: "Fn 语音输入法")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(localized: "text.1e3975f890bc", defaultValue: "Typeless / 微信语音 / 豆包输入法使用 F19 触发，并注入 Fn 按住/松开。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "text.535028edfa7e", defaultValue: "排查请看 voice-relay.log（matched · function relay · post fn）。路径：~/Library/Application Support/AhaKeyConfig/diagnostics/"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button(String(localized: "text.53743dbf4834", defaultValue: "模拟按一次语音键")) {
                                voiceRelay.simulateInspectorVoiceKeyTap(for: selectedMode)
                            }
                            .buttonStyle(.borderedProminent)
                            if let hint = voiceRelay.lastInspectorSimulateHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox(String(localized: "text.c5baf691ae6f", defaultValue: "AhaType 状态")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(isOn: Binding(
                                get: { ahaType.isEnabled },
                                set: { ahaType.setEnabled($0) }
                            )) {
                                Text(String(localized: "text.c2977d90de54", defaultValue: "AhaType 云端整理"))
                                    .font(.callout.weight(.semibold))
                            }
                            .toggleStyle(.switch)
                            Spacer()
                            Button(String(localized: "text.aee887434131", defaultValue: "刷新")) { ahaType.refreshFromDisk() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        Text(ahaType.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ahaType.lastQuotaSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(width: 500, height: 620)
    }

    // MARK: - Inspector Level 1 Summary

    private func summaryRow(_ title: String, value: String, dot: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 5) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .offset(y: -1)
                }
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var partSummaryContent: some View {
        switch selectedPart {
        case .key1:          voiceKeySummary
        case .key2, .key3, .key4: actionKeySummary
        case .oledDisplay:   oledSummary
        case .lightBar:      lightBarSummary
        case .toggleSwitch:  switchSummary
        }
    }

    @ViewBuilder
    private var voiceKeySummary: some View {
        let key = currentSelectedKey
        let preset = key.voicePreset ?? .custom
        summaryRow(String(localized: "text.0c1d0269f51e", defaultValue: "输入方式"), value: preset.title)
        summaryRow(String(localized: "text.ee2638183d3e", defaultValue: "快捷键"), value: key.displaySummary)
        if preset.isMacOSNativeFamily {
            summaryRow(String(localized: "text.3c7b79b73494", defaultValue: "触发方式"), value: String(localized: "text.fed7c2cd961a", defaultValue: "短按 + 长按"))
            let permCount = [nativeSpeech.microphoneGranted, nativeSpeech.speechRecognitionGranted,
                             nativeSpeech.siriEnabled, nativeSpeech.dictationEnabled].filter { $0 }.count
            summaryRow(String(localized: "text.0bc1396da014", defaultValue: "转写权限"), value: String(localized: "text.8e898731e368", defaultValue: "\(String(describing: permCount))/4 已授权"),
                       dot: permCount == 4 ? .green : .orange)
        }
        summaryRow(String(localized: "text.adbeb86c768f", defaultValue: "语音桥"), value: voiceRelay.isListening ? String(localized: "text.1f0eb99b7ed0", defaultValue: "运行中") : String(localized: "text.b77382c6b2fa", defaultValue: "等待权限"),
                   dot: voiceRelay.isListening ? .green : .orange)
        summaryRow(String(localized: "text.af689366f16d", defaultValue: "按键描述"), value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var actionKeySummary: some View {
        let key = currentSelectedKey
        summaryRow(String(localized: "text.3dd97f4d2766", defaultValue: "绑定"), value: key.displaySummary)
        summaryRow(String(localized: "text.ba40014ff496", defaultValue: "类型"), value: key.usesMacro ? String(localized: "text.7e06bc4d9ae8", defaultValue: "固件宏（\(key.macro.count) 步）") : String(localized: "text.054a6d6229c3", defaultValue: "单键 / 组合键"))
        summaryRow(String(localized: "text.af689366f16d", defaultValue: "按键描述"), value: key.description.isEmpty ? "—" : key.description)
    }

    @ViewBuilder
    private var oledSummary: some View {
        let oled = currentModeDraft.oled
        summaryRow(String(localized: "text.2d1832263007", defaultValue: "动图"), value: oled.localAssetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "text.e7a3603b5715", defaultValue: "默认动图"))
        summaryRow(String(localized: "text.c114a632b201", defaultValue: "播放速度"), value: "\(oled.framesPerSecond) FPS")
        summaryRow(String(localized: "text.824eb39ccace", defaultValue: "状态行"), value: oled.statusLine.isEmpty ? "—" : String(oled.statusLine.prefix(32)))
    }

    @ViewBuilder
    private var lightBarSummary: some View {
        let lb = currentModeDraft.lightBar
        ForEach(IDEState.allCases) { state in
            summaryRow(state.shortLabel, value: lb.effect(for: state).title)
        }
        summaryRow(String(localized: "text.8e2f643ad160", defaultValue: "亮度"), value: "\(lb.brightness)%")
    }

    @ViewBuilder
    private var switchSummary: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        summaryRow(String(localized: "text.c993795f681b", defaultValue: "当前档位"), value: currentSwitchTitle,
                   dot: liveKeyboardSwitchState == 0 ? .green : .indigo)
        summaryRow("Agent", value: agentReady ? String(localized: "text.b073db9c0bd6", defaultValue: "就绪") : String(localized: "text.e5c84c9aa782", defaultValue: "未就绪"),
                   dot: agentReady ? .green : .orange)
        summaryRow(String(localized: "text.c5101b7782e3", defaultValue: "作用范围"), value: "Claude · Cursor · Codex · Kimi")
    }

    // MARK: - Inspector Level 2 Detail

    private var keyInspector: some View {
        let key = currentSelectedKey
        return VStack(alignment: .leading, spacing: 16) {
            GroupBox(String(localized: "text.af689366f16d", defaultValue: "按键描述")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(String(localized: "text.fafd6b15ca5c", defaultValue: "例如 Record / Accept / Reject / Backspace"), text: selectedKeyDescriptionBinding)
                        .textFieldStyle(.roundedBorder)
                    if currentSelectedKey.description.containsNonASCII {
                        Text(String(localized: "text.bc9aba91eae4", defaultValue: "设备 LCD 只稳定支持 ASCII。中文、emoji 和全角字符会在写入时被自动过滤，避免乱码。"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(String(localized: "text.231ba7c26233", defaultValue: "设备实际写入：\(String(describing: currentSelectedKeySanitizedDescription.isEmpty ? String(localized: "text.f0bf4574ce25", defaultValue: "空白") : currentSelectedKeySanitizedDescription))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "text.5317650971bb", defaultValue: "同步到键盘后，短按实体键切换模式时，LCD 会先短暂显示这里的描述，然后回到该模式的动图。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if selectedMode == .mode0 {
                        Text(String(localized: "text.cebd5ebda545", defaultValue: "Mode 1 默认文案：Record / Accept / Reject / Backspace"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            if key.role == .voice {
                GroupBox(String(localized: "text.19b30fbb9fb8", defaultValue: "语音输入方式")) {
                    VStack(alignment: .leading, spacing: 12) {
                        VoicePresetPicker(
                            selectedPreset: key.voicePreset ?? .custom,
                            onSelect: applyVoicePreset
                        )
                        if (key.voicePreset ?? .custom).isMacOSNativeFamily {
                            Text(String(localized: "text.298a41613998", defaultValue: "只要 AhaKey Studio 在后台运行，Mode 1 出厂语音键发出的 F18 就会被直接接管到苹果原生转写。现在不再依赖系统听写快捷键。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(localized: "text.50a3e9bd844e", defaultValue: "语音键的输入方式独立于当前 Mode，在任意 Mode 下都可使用相同的语音输入设置。"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
            } else {
                GroupBox(String(localized: "text.ab2599708410", defaultValue: "按键职责")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.role.manualText)
                            .font(.callout)
                        Text(String(localized: "text.e3adb8f59948", defaultValue: "当前会把快捷键和按键描述一起写入键盘。切换模式时，设备会先显示描述，再回到该模式的 LCD 动图。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // ── 触发方式（短按 / 长按 Tab）──────────────────────────────
            GroupBox(String(localized: "text.3c7b79b73494", defaultValue: "触发方式")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedTriggerTab) {
                        Text(String(localized: "text.de8be63f4493", defaultValue: "短按")).tag(0)
                        Text(String(localized: "text.a22fbb4c391a", defaultValue: "长按")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Divider()

                    if key.role == .voice {
                        // ── 语音键触发方式 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(String(localized: "text.594056f96ae0", defaultValue: "按一下开始，再按一下结束"), systemImage: "hand.tap.fill")
                                    .font(.callout.weight(.semibold))
                                Text(String(localized: "text.c85fb846cf94", defaultValue: "录音结束后根据下方开关决定是否经 AhaType 整理，再写入光标。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.shortPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text(String(localized: "text.fc5a07ded2c3", defaultValue: "使用 AhaType 整理"))
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text(String(localized: "text.7248368112b4", defaultValue: "（AhaType 总开关已关闭）"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)

                                Divider()

                                // 绑定摘要（短按 = 语音键 HID 绑定）
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(key.usesMacro ? String(localized: "text.14649746608f", defaultValue: "固件宏") : String(localized: "text.1d770500d6ee", defaultValue: "底层 HID"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text(String(localized: "text.054a6d6229c3", defaultValue: "单键 / 组合键")).tag(KeyBindingMode.shortcut)
                                    Text(String(localized: "text.d2ecd2ac93a3", defaultValue: "宏")).tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .disabled((key.voicePreset ?? .custom) != .custom)
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                                Text(voicePresetDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if (key.voicePreset ?? .custom) != .custom {
                                    Text(String(localized: "text.fad8799c7c3e", defaultValue: "语音键预设会固定使用单键绑定；如需录制宏，请先把预设改为自定义快捷键。"))
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } else {
                            // 长按 Tab（语音键）— 始终开启，仅配置 AhaType 与阈值
                            VStack(alignment: .leading, spacing: 10) {
                                Label(String(localized: "text.9dfa5e4ba0ac", defaultValue: "按住录音，松手即发送"), systemImage: "hand.draw.fill")
                                    .font(.callout.weight(.semibold))
                                Text(String(localized: "text.80575ae92e8a", defaultValue: "按住键盘录音键不松手开始录音，松手后直接将 ASR 结果写入，响应更快。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Toggle(isOn: $nativeSpeech.longPressAhaTypeEnabled) {
                                    HStack(spacing: 6) {
                                        Text(String(localized: "text.fc5a07ded2c3", defaultValue: "使用 AhaType 整理"))
                                            .font(.callout)
                                        if !ahaType.isEnabled {
                                            Text(String(localized: "text.7248368112b4", defaultValue: "（AhaType 总开关已关闭）"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.switch)
                                .disabled(!ahaType.isEnabled)
                                HStack(spacing: 10) {
                                    Text(String(localized: "text.aaae142015b7", defaultValue: "触发阈值"))
                                        .font(.callout)
                                    Slider(
                                        value: Binding(
                                            get: { Double(nativeSpeech.longPressThresholdMs) },
                                            set: { nativeSpeech.longPressThresholdMs = Int($0) }
                                        ),
                                        in: 200...1000,
                                        step: 50
                                    )
                                    Text("\(nativeSpeech.longPressThresholdMs) ms")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 58, alignment: .trailing)
                                }
                            }
                        }
                    } else {
                        // ── 普通键触发方式 ──────────────────────────────
                        if selectedTriggerTab == 0 {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(key.displaySummary)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .lineLimit(2)
                                    Spacer()
                                    Text(key.usesMacro ? String(localized: "text.14649746608f", defaultValue: "固件宏") : String(localized: "text.1d770500d6ee", defaultValue: "底层 HID"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Picker("", selection: selectedKeyBindingModeBinding) {
                                    Text(String(localized: "text.054a6d6229c3", defaultValue: "单键 / 组合键")).tag(KeyBindingMode.shortcut)
                                    Text(String(localized: "text.d2ecd2ac93a3", defaultValue: "宏")).tag(KeyBindingMode.macro)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                if key.usesMacro {
                                    macroEditor(for: key)
                                } else {
                                    ShortcutBindingEditor(shortcut: selectedKeyShortcutBinding)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(String(localized: "text.89b8f250e8ef", defaultValue: "需要固件 v2+ 支持"), systemImage: "exclamationmark.triangle")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text(String(localized: "text.8b98e4a3b2dd", defaultValue: "长按绑定不同快捷键需固件升级后生效，当前仅短按绑定会写入设备。"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .onChange(of: selectedPart) { _ in selectedTriggerTab = 0 }

        }
    }

    // MARK: - 宏编辑器视图

    @ViewBuilder
    private func macroEditor(for key: AhaKeyKeyDraft) -> some View {
        let stepCount = key.macro.count
        let byteCount = stepCount * 2
        let overLimit = byteCount > 98 // 固件 payload 上限

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "text.102c9114561e", defaultValue: "步骤（依次执行）"))
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(String(localized: "text.f7baeeda4d19", defaultValue: "\(String(describing: stepCount)) 步 · \(String(describing: byteCount)) / 98 字节"))
                    .font(.caption)
                    .foregroundStyle(overLimit ? .red : .secondary)
            }

            if key.macro.isEmpty {
                Text(String(localized: "text.f5cd7400d45e", defaultValue: "空宏。点下方「添加步骤」开始录制。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(key.macro.enumerated()), id: \.element.id) { index, step in
                        macroStepRow(
                            index: index,
                            step: step,
                            totalCount: key.macro.count
                        )
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    appendMacroStep()
                } label: {
                    Label(String(localized: "text.f2ee4d080167", defaultValue: "添加步骤"), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(overLimit)

                Button(role: .destructive) {
                    updateSelectedKey { $0.macro = [] }
                } label: {
                    Label(String(localized: "text.1ef3de06b32e", defaultValue: "清空"), systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(key.macro.isEmpty)
            }

            if overLimit {
                Text(String(localized: "text.2c7116d872d6", defaultValue: "超过固件单键宏 98 字节 / 49 步上限，同步时会被拒绝。"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(String(localized: "text.9c91d63bea2b", defaultValue: "固件按顺序串行发送；延时单位 3ms（最大 765ms）。需要更长延时请叠加多个延时步骤。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !key.macro.isEmpty {
                Text(String(localized: "text.36cfab570ea2", defaultValue: "预览：\(String(describing: key.macro.displaySummary))"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func macroStepRow(index: Int, step: MacroStep, totalCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Picker("", selection: macroStepActionBinding(id: step.id)) {
                ForEach(MacroAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)

            if step.action.takesKeycodeParam {
                Picker("", selection: macroStepKeycodeBinding(id: step.id)) {
                    Text(String(localized: "text.2f5f1d6fbfb0", defaultValue: "未设置")).tag(UInt8(0))
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 96)
            } else if step.action.takesDelayParam {
                // 勿对带标题的 Stepper 用 labelsHidden()，否则连「15 ms」一并被藏掉。
                HStack(spacing: 8) {
                    Text("\(max(1, Int(step.param)) * 3) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, alignment: .trailing)
                    Stepper(
                        "",
                        value: macroStepDelayBinding(id: step.id),
                        in: 1...255
                    )
                    .labelsHidden()
                }
                .frame(minWidth: 120)
            } else {
                Color.clear.frame(minWidth: 96, maxHeight: 1)
            }

            Spacer(minLength: 0)

            Button {
                moveMacroStep(from: index, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                moveMacroStep(from: index, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(index >= totalCount - 1)

            Button(role: .destructive) {
                removeMacroStep(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    private func macroStepActionBinding(id: UUID) -> Binding<MacroAction> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.action ?? .noOp
            },
            set: { newAction in
                updateMacroStep(id: id) { step in
                    let previous = step.action
                    step.action = newAction
                    // 动作换类别后清零 param，避免把 "Enter 的 HID 码 0x28" 当成延时值 ×3ms 解读。
                    if previous.takesKeycodeParam != newAction.takesKeycodeParam
                        || previous.takesDelayParam != newAction.takesDelayParam
                    {
                        switch newAction {
                        case .delay:
                            step.param = 5 // 默认 15ms，比较通用
                        case .downKey, .upKey:
                            step.param = HIDUsage.enter
                        case .noOp, .upAllKeys:
                            step.param = 0
                        }
                    }
                }
            }
        )
    }

    private func macroStepKeycodeBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private func macroStepDelayBinding(id: UUID) -> Binding<UInt8> {
        Binding(
            get: {
                currentSelectedKey.macro.first { $0.id == id }?.param ?? 0
            },
            set: { newValue in
                updateMacroStep(id: id) { $0.param = newValue }
            }
        )
    }

    private var oledInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(String(localized: "text.75dfc191dc49", defaultValue: "当前模式的 LCD 动图")) {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.9))
                            .frame(height: 140)

                        if let path = currentModeDraft.oled.localAssetPath {
                            AnimatedGIFView(
                                path: path,
                                fps: currentModeDraft.oled.framesPerSecond
                            )
                                .frame(height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.artframe")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text(String(localized: "text.6ef9ce9697f5", defaultValue: "当前仅支持动图"))
                                    .foregroundStyle(.white.opacity(0.85))
                                Text(String(localized: "text.77dfb775567f", defaultValue: "文字、token、模型状态显示开发中"))
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(String(localized: "text.dedc9ffc46db", defaultValue: "选择 GIF 或图片")) {
                            selectOLEDGIF()
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "text.93087460989a", defaultValue: "预览动图")) {
                            showsOLEDPlaybackPreview = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(currentModeDraft.oled.localAssetPath == nil)

                        Button(String(localized: "text.1ef3de06b32e", defaultValue: "清空")) {
                            clearCurrentOLED()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text(String(localized: "text.e3966f2ff0c3", defaultValue: "当前目标：\(String(describing: selectedMode.title))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Stepper(value: oledFramesPerSecondBinding, in: 1 ... 30) {
                        Text(String(localized: "text.95b85df296ff", defaultValue: "播放速度 \(String(describing: currentModeDraft.oled.framesPerSecond)) FPS"))
                    }

                    Text(String(localized: "text.9a7bc446ba51", defaultValue: "硬性限制：源文件 ≤ 2 MB，FPS 1–30，单模式最多 70 帧；Mode 1/2/3/4 固定写入 slot 10/80/150/220。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(currentModeDraft.oled.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            GroupBox(String(localized: "text.32ad135f1632", defaultValue: "显示逻辑")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "text.15f31ea994c0", defaultValue: "切换到当前模式时，LCD 会先显示该模式的按键描述，约 1 秒后回到该模式动图。"))
                    Text(String(localized: "text.1cbfe1869ae2", defaultValue: "后续会继续增加文字状态、token 用量、模型环境等信息显示能力。"))
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var lightBarInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if bleManager.supportsConfigurableLighting == false {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(localized: "text.3eed5c499ddf", defaultValue: "当前键盘固件不支持可写灯效"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(String(localized: "text.79206ae8d42e", defaultValue: "旧 v1.0 会对未实现的 0x84/0x85/0x91 返回“成功”，但不会改灯。请先刷入 2026-06-22 后的新固件；客户端已禁止把这种假 ACK 当作写入成功。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if bleManager.supportsConfigurableLighting == true {
                Label(String(localized: "text.077afdfb43e2", defaultValue: "新灯效协议已就绪（0x84 / 0x85 / 0x91）"), systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            GroupBox(String(localized: "text.bc880bfe60ed", defaultValue: "状态灯效映射")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(IDEState.workflowOrder) { state in
                        HStack {
                            Text(state.shortLabel)
                                .font(.callout.weight(.medium))
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: lightEffectBinding(for: state)) {
                                ForEach(LightEffectStyle.allCases) { effect in
                                    Text(effect.title).tag(effect)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.top, 4)
            }

            GroupBox(String(localized: "text.8e2f643ad160", defaultValue: "亮度")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Slider(value: brightnessBinding, in: 1...100, step: 1)
                        Text("\(currentModeDraft.lightBar.brightness)%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.top, 4)
            }

            GroupBox(String(localized: "text.1ea06a9233cf", defaultValue: "状态预览")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lightBarPreview.shortLabel)
                        .font(.system(.title3, design: .rounded).weight(.semibold))

                    Text(String(localized: "text.092fd3faf27f", defaultValue: "画布预览：\(String(describing: currentModeDraft.lightBar.effect(for: lightBarPreview).title))"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "text.19c27ccf7186", defaultValue: "点击状态会在虚拟键盘预览，并通过 0x91 临时预览到设备；保存请使用底部通用按钮。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                        ForEach(IDEState.workflowOrder) { state in
                            Button {
                                lightBarPreview = state
                                previewLightEffect(for: state)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(state.shortLabel)
                                        .font(.caption.weight(.semibold))
                                    Text(currentModeDraft.lightBar.effect(for: state).title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(state == lightBarPreview ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(state == lightBarPreview ? Color.accentColor : Color.black.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var switchInspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(String(localized: "text.571287543686", defaultValue: "实时档位")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(currentSwitchTitle)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                        Spacer()
                        Circle()
                            .fill(liveKeyboardSwitchState == 0 ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                    }
                    Text(String(localized: "text.ced5a84c87cd", defaultValue: "拨杆是物理档位，不是按下瞬态。0 档显示「自动批准」，1 档显示「手动批准」。这里只读取键盘上报的位置，不模拟物理拨动。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            switchEffectivenessBox

            if bleManager.switchState == 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "text.eaeee3c6a45b", defaultValue: "自动批准依赖 Agent 与 Hook，且须蓝牙由 Agent 占用"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "text.d87a85a910aa", defaultValue: "Claude：PermissionRequest allow。Cursor：preToolUse 等与 cli-config。Codex：PermissionRequest allow。Kimi：安装过 AhaKey Kimi Hooks 后，**拨杆会直接接管当前会话的自动批准**；若刚装完或刚升级 kimi-cli，请**完全关闭并重新打开一次 kimi**。钩子 stdout 只对 **`permissionDecision: deny`** 有特殊拦截语义。Agent 须在跑且蓝牙由其占用。"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            GroupBox(String(localized: "text.936cc19243b4", defaultValue: "如何理解这个部件")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "text.df936d8c612c", defaultValue: "拨杆对 Claude / Cursor / Codex / Kimi **同时生效**，与键盘当前所在 Mode 无关。Agent 后台同时监听所有 IDE 的 Hook，拨杆拨动后四个 IDE 的批准行为立即切换。"))
                    Divider()
                    Text(String(localized: "text.9fd2f730247f", defaultValue: "自动批准：**Claude / Codex PermissionRequest**，**Cursor preToolUse**（含 cli-config）。**Kimi**：安装过 AhaKey Kimi Hooks 后，拨杆会直接接管**当前会话**的自动批准；刚装完或刚升级 kimi-cli 时，重开一次 kimi 即可。"))
                    Text(String(localized: "text.ec0a7ed5f35a", defaultValue: "手动批准：会交回用户/终端确认。若 Cursor、Codex 或 Kimi 仍弹窗，请看 diagnostics 里的 ide 与 diagnostic 字段。"))
                    Text(String(localized: "text.6c7011111614", defaultValue: "若仍出现手动：在「设备信息」里打开「工具批准诊断」查看 permission-request.log（含 ide、hookEvent、diagnostic 等）。"))
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var switchEffectivenessBox: some View {
        let agentReady = agentManager.isInstalled && agentManager.isRunning && agentManager.hooksInstalled
        let hasAnyMissing = !agentManager.isInstalled || !agentManager.isRunning || !agentManager.hooksInstalled
        GroupBox(agentReady ? String(localized: "text.8d544e154955", defaultValue: "已生效") : String(localized: "text.bb68468fb7d3", defaultValue: "未生效")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: agentReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(agentReady ? .green : .orange)
                    Text(agentReady
                         ? String(localized: "text.c826bc275c16", defaultValue: "Agent 就绪时 Claude/Cursor/Codex 可随拨杆走批准。**Kimi**：安装过 AhaKey Kimi Hooks 后，拨杆会直接接管当前会话；若刚装完或刚升级 kimi-cli，重开一次 kimi 即可。")
                         : String(localized: "text.2ecb45a3b309", defaultValue: "拨杆在 IDE 中生效需先安装 Agent 与 Hook，并把蓝牙交给 Agent；否则仅为状态显示。"))
                        .font(.callout)
                }

                if hasAnyMissing {
                    VStack(alignment: .leading, spacing: 4) {
                        agentChecklistRow(label: String(localized: "text.f30615080777", defaultValue: "LaunchAgent 已安装"), ok: agentManager.isInstalled)
                        agentChecklistRow(label: String(localized: "text.78e3b7a3c292", defaultValue: "Agent 已连接蓝牙"), ok: agentManager.isRunning)
                        agentChecklistRow(label: String(localized: "text.aa1d4e523fdf", defaultValue: "Claude / Cursor / Codex / Kimi Hook 已配置"), ok: agentManager.hooksInstalled)
                    }
                    .padding(.leading, 4)

                    HStack(spacing: 8) {
                        if !agentManager.isInstalled {
                            Button(String(localized: "text.5958f0b1d9ad", defaultValue: "安装 Agent + Hook")) {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if !agentManager.isRunning {
                            // 与「设备信息 · Agent」相同：在 launchd 中 load + start 守护进程。
                            // 若当前由本 App 占用蓝牙，此处也应引导先去设备信息把「蓝牙连接」切给 Agent，否则与主流程二选一相冲突（故与 DeviceInfo 同样禁用直接启动）。
                            Button(String(localized: "text.796804055103", defaultValue: "启动 Agent")) {
                                agentManager.start()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                            .help(
                                agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                                ? String(localized: "text.5273a691e14a", defaultValue: "当前由本 App 占用蓝牙。请打开下方「设备信息…」，在「蓝牙连接」里选「由 Agent 占用」后再启 Agent；与设备信息里「启动」按钮规则一致。")
                                : String(localized: "text.ff726e02e183", defaultValue: "与「设备信息 · Agent」中的启动相同，由 launchd 加载并执行 ahakeyconfig-agent。")
                            )
                        }
                        Button(String(localized: "text.14cc6eb61a5f", defaultValue: "设备信息（蓝牙 / 启停 Agent）…")) {
                            showsDeviceInfo = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func agentChecklistRow(label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }


    private var statusBar: some View {
        HStack(spacing: 16) {
            Label("\(selectedPart.title) · \(selectedMode.title)", systemImage: selectedPart.systemImage)
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text(String(localized: "text.741374ef7519", defaultValue: "未同步改动 \(String(describing: dirtyCount))"))
                .font(.callout)
            Divider()
                .frame(height: 14)
            Text(syncStatusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let lastSyncDate {
                Text(String(localized: "text.6dbd32a3f5b0", defaultValue: "最近同步 \(String(describing: Self.timeFormatter.string(from: lastSyncDate)))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(String(localized: "text.22aa5b3f29c5", defaultValue: "权限诊断")) {
                showsDiagnostics = true
            }
            .buttonStyle(.borderless)
            .help(String(localized: "text.fd9338762e65", defaultValue: "查看语音权限状态与诊断日志"))
            .sheet(isPresented: $showsDiagnostics) {
                diagnosticsSheet
            }

            Button(String(localized: "text.9d7d3c079d17", defaultValue: "新手引导")) {
                voiceRelay.showsPermissionOnboarding = false
                unifiedOnboardingCompleted = false
            }
            .buttonStyle(.borderless)
            .help(String(localized: "text.73cb6cee4904", defaultValue: "重新打开 AhaKey Studio 新手引导"))

            Button(String(localized: "text.dc0179998b33", defaultValue: "帮助中心")) {
                showsHelpCenter = true
            }
            .buttonStyle(.borderless)
            .help(String(localized: "text.331070589051", defaultValue: "打开内嵌的帮助中心"))
            .sheet(isPresented: $showsHelpCenter) {
                HelpCenterSheet(
                    studioDraft: studioDraft,
                    selectedMode: selectedMode,
                    bleManager: bleManager
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(chromeBarBackground)
    }

    private var chromeBarBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var currentModeDraft: AhaKeyModeDraft {
        studioDraft.draft(for: selectedMode)
    }

    private var currentSelectedKey: AhaKeyKeyDraft {
        let role = selectedPart.keyRole ?? .voice
        return currentModeDraft.key(for: role)
    }

    private var currentSwitchTitle: String {
        // 用统一的 liveKeyboardSwitchState：主 App 自占 BLE 时是 bleManager.switchState，
        // 否则取 agent 共享文件里的值（含用户拨杆覆盖）。否则点了画布拨杆，
        // 因为 bleManager.switchState 一直是初始 0，画布会一直停留在「自动批准」。
        liveKeyboardSwitchState == 0 ? String(localized: "text.33a4c1e02545", defaultValue: "自动批准") : String(localized: "text.4f87c2cea203", defaultValue: "手动批准")
    }

    /// 取键盘当前实时状态 (lightMode/switchState/workMode)：
    /// - 主 App 已自连 BLE（编辑配置时）→ 用主 App 自己的 BLE 读数
    /// - 主 App 未连，但 agent 仍占用 BLE 在写共享文件 → 读 agent 发布的缓存
    /// - 两者都没有 → nil（画布回落到模拟）
    private var liveKeyboardLightMode: Int? {
        if bleManager.isConnected { return bleManager.lightMode }
        return bleManager.agentLightMode
    }
    private var liveKeyboardSwitchState: Int {
        // 用户刚点完虚拟拨杆但 agent / BLE 还没回报新值时，优先用乐观值，按下立刻可见
        if let opt = bleManager.optimisticSwitchOverride { return opt }
        if bleManager.isConnected { return bleManager.switchState }
        return bleManager.agentSwitchState ?? 1
    }
    private var liveKeyboardWorkMode: Int? {
        if bleManager.isConnected { return bleManager.workMode }
        return bleManager.agentWorkMode
    }
    private var liveCanvasLightMode: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return liveKeyboardLightMode
    }
    private var liveCanvasIDEStateValue: Int? {
        guard let workMode = liveKeyboardWorkMode, selectedMode.rawValue == workMode else { return nil }
        return bleManager.liveIDEStateValue
    }
    private var liveCanvasSwitchState: Int { liveKeyboardSwitchState }

    private func cycleModeForward() {
        let all = AhaKeyModeSlot.allCases
        let next = all[(all.firstIndex(of: selectedMode)! + 1) % all.count]
        selectedMode = next
    }

    /// 用户点击虚拟拨杆：在当前 effective switchState 基础上 0↔1 翻转，
    /// 只设置软件覆盖；最新固件中 0x91 是灯效预览，不再用于 sw_state。
    private func toggleVirtualSwitch() {
        let current = liveKeyboardSwitchState
        let next: UInt8 = current == 0 ? 1 : 0
        // 1) 立刻设乐观值 → 画布按钮即时翻转
        bleManager.applyOptimisticSwitchOverride(next)
        // 2) 保留调用入口，但 BLEManager 不会再发送旧 0x91，只写诊断日志
        if bleManager.isConnected {
            bleManager.setSwitchStateViaBLE(next)
        }
        // 3) 让 agent 设置软覆盖
        AgentManager.shared.sendSwitchOverride(next)
        // 4) 短延迟后强制重读共享文件，确认真实值已对齐（agent 写文件通常 < 100ms）
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak bleManager] in
            bleManager?.refreshAgentStateFromFileNow()
        }
        syncStatusMessage = next == 0
            ? String(localized: "text.3503a7cca409", defaultValue: "虚拟拨杆 → 自动批准（hook 自动放行；灯效若不变需先刷支持 0x91 的固件）")
            : String(localized: "text.cf35583346c4", defaultValue: "虚拟拨杆 → 手动批准（hook 交回终端确认）")
    }

    private var currentOLEDAssetURL: URL? {
        guard let path = currentModeDraft.oled.localAssetPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var currentLightEffect: LightEffectStyle {
        currentModeDraft.lightBar.effect(for: lightBarPreview)
    }

    private var isEditingConfiguration: Bool {
        agentManager.bluetoothConnectionOwner == .ahaKeyStudio
    }

    // AhaKeyStudio 直连、Agent 已连上键盘、或正在交还蓝牙的过渡期，任一满足即视为设备已连接。
    private var isEffectivelyConnected: Bool {
        bleManager.isConnected || agentManager.isAgentBLEConnected || isTransitioningToKeyboardControl
    }

    private var shouldShowTopBarInstallStartButton: Bool {
        !agentManager.isInstalled || !agentManager.hooksInstalled
    }

    private var configurationModeDetail: String {
        if isEditingConfiguration {
            if bleManager.isConnected {
                return String(localized: "text.58a0ce6ce8b0", defaultValue: "AhaKey Studio 正在配置键盘")
            }
            return bleManager.isScanning ? String(localized: "text.fab8f6f1fbdf", defaultValue: "AhaKey Studio 正在连接键盘") : String(localized: "text.ca31df8bfcd4", defaultValue: "AhaKey Studio 等待连接键盘")
        }
        // 蓝牙交给 Agent：若顶栏仍显示「安装启动」，说明 Hook/Agent 未齐备，勿与左侧「已连接」拼成「已可控制」。
        if !isEditingConfiguration && shouldShowTopBarInstallStartButton && isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return String(localized: "text.e6d8914d0530", defaultValue: "Agent 正在控制键盘")
            }
            return String(localized: "text.22ccc7f33029", defaultValue: "安装启动后才能控制键盘")
        }
        // 蓝牙交给 Agent 时：与左侧 infoPill「已连接」口径一致（isEffectivelyConnected），避免出现「已连接」+「等待键盘」的互斥文案。
        if isEffectivelyConnected {
            if agentManager.isRunning && agentManager.isAgentBLEConnected {
                return String(localized: "text.e6d8914d0530", defaultValue: "Agent 正在控制键盘")
            }
            if agentManager.isRunning {
                return String(localized: "text.a1859da180b1", defaultValue: "键盘已连接；正在同步 Agent 连接状态")
            }
            return String(localized: "text.1312a31d2068", defaultValue: "键盘已连接")
        }
        if agentManager.isRunning {
            return String(localized: "text.dd7742a1e36d", defaultValue: "Agent 运行中，等待键盘连接")
        }
        if agentManager.isInstalled {
            return String(localized: "text.da692945eeca", defaultValue: "Agent 已安装，正在准备控制")
        }
        return String(localized: "text.ac33b06d9280", defaultValue: "需要安装 Agent 后才能控制键盘")
    }

    private var configurationModeButtonTitle: String {
        if isSyncing {
            return String(localized: "text.4e2238b74ec7", defaultValue: "同步中…")
        }
        if isEditingConfiguration {
            return String(localized: "text.6e584e3d5ce6", defaultValue: "保存配置")
        }
        return String(localized: "text.b2b5b9fafa31", defaultValue: "编辑配置")
    }

    private var configurationModeButtonHelp: String {
        if isEditingConfiguration {
            if hasUnsyncedChanges {
                return String(localized: "text.a0889cda9f6a", defaultValue: "将当前草稿同步到键盘，然后把蓝牙交还给 Agent。")
            }
            return String(localized: "text.7a58a85f457e", defaultValue: "没有未同步改动，直接把蓝牙交还给 Agent。")
        }
        return String(localized: "text.d423742e2b1a", defaultValue: "临时由 AhaKey Studio 接管蓝牙，用于改键、LCD、同步和本机灯效测试。")
    }

    private var voicePresetDetail: String {
        let preset = currentSelectedKey.voicePreset ?? .custom
        return preset.detail
    }

    private func permissionBadge(title: String, granted: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(granted ? String(localized: "text.8a4ef3e48e4e", defaultValue: "已开启") : String(localized: "text.3cffa9757b69", defaultValue: "未开启"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 999)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var currentSelectedKeySanitizedDescription: String {
        currentSelectedKey.description.sanitizedASCII(maxLength: 20)
    }

    private var selectedKeyDescriptionBinding: Binding<String> {
        Binding(
            get: { currentSelectedKey.description },
            set: { newValue in
                updateSelectedKey { key in
                    key.description = String(newValue.prefix(20))
                }
            }
        )
    }

    private var selectedKeyShortcutBinding: Binding<ShortcutBinding> {
        Binding(
            get: { currentSelectedKey.shortcut },
            set: { newValue in
                updateSelectedKey { $0.shortcut = newValue }
            }
        )
    }

    private var oledFramesPerSecondBinding: Binding<Int> {
        Binding(
            get: { currentModeDraft.oled.framesPerSecond },
            set: { newValue in
                updateCurrentMode { mode in
                    mode.oled.framesPerSecond = min(30, max(1, newValue))
                }
            }
        )
    }

    private var hasUnsyncedChanges: Bool {
        dirtyCount > 0
    }

    private var dirtyCount: Int {
        AhaKeyModeSlot.allCases.reduce(into: 0) { count, mode in
            let current = studioDraft.draft(for: mode)
            let baseline = lastSyncedDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases where current.key(for: role) != baseline.key(for: role) {
                count += 1
            }
            if !current.oled.hasSameDeviceConfiguration(as: baseline.oled) {
                count += 1
            }
            if current.lightBar != baseline.lightBar {
                count += 1
            }
        }
    }

    private func restoreCurrentModeDefaults() {
        let restored = AhaKeyModeDraft.default(for: selectedMode)
        var next = studioDraft
        next.updateMode(restored)
        studioDraft = next
        syncStatusMessage = String(localized: "text.24b148bb01ff", defaultValue: "\(String(describing: selectedMode.title)) 已恢复默认值，等待同步。")
    }

    private func clearCurrentOLED() {
        updateCurrentMode { mode in
            mode.oled.localAssetPath = nil
            mode.oled.statusLine = AhaKeyOLEDDraft.default(for: selectedMode).statusLine
        }
    }

    private func applyVoicePreset(_ preset: VoicePreset) {
        updateSelectedKey { key in
            key.voicePreset = preset
            if preset != .custom {
                key.shortcut = preset.defaultBinding
            }
            if key.description.isEmpty {
                key.description = key.role.defaultDescription
            }
        }
    }

    // MARK: - 宏编辑

    /// 按键当前处于 "宏" 还是 "快捷键" 录入模式。
    /// 状态仅由 `macro` 是否为空推导，避免多出一个独立 flag。
    private enum KeyBindingMode {
        case shortcut
        case macro
    }

    private var selectedKeyBindingModeBinding: Binding<KeyBindingMode> {
        Binding(
            get: { currentSelectedKey.usesMacro ? .macro : .shortcut },
            set: { newValue in
                switch newValue {
                case .shortcut:
                    updateSelectedKey { key in
                        key.macro = []
                    }
                case .macro:
                    updateSelectedKey { key in
                        guard key.macro.isEmpty else { return }
                        // Mode 0「No」键的 shortcut 故意为空，实际绑定是固件宏 ↓↓⏎；若仍用「空 shortcut → Enter 种子」，
                        // 从「单键」切回「宏」时会被误植成只按 Enter，覆盖用户刚配好的三键宏。
                        if selectedMode == .mode0, key.role == .reject {
                            key.macro = AhaKeyModeDraft.claudeNoMacroSteps.map { step in
                                MacroStep(action: step.action, param: step.param)
                            }
                            return
                        }
                        // 其它键：用当前 shortcut 的主键作种子（没配就用 Enter），避免空白宏列表。
                        let seed: UInt8 = key.shortcut.keyCode == 0 ? HIDUsage.enter : key.shortcut.keyCode
                        key.macro = [
                            MacroStep(action: .downKey, param: seed),
                            MacroStep(action: .upKey, param: seed),
                        ]
                    }
                }
            }
        )
    }

    private func appendMacroStep() {
        updateSelectedKey { key in
            // 默认追加 "按下 Enter"——多数用户添加步骤都是想按键，延时/松开可以再切。
            key.macro.append(MacroStep(action: .downKey, param: HIDUsage.enter))
        }
    }

    private func removeMacroStep(at index: Int) {
        updateSelectedKey { key in
            guard key.macro.indices.contains(index) else { return }
            key.macro.remove(at: index)
        }
    }

    private func moveMacroStep(from index: Int, by offset: Int) {
        updateSelectedKey { key in
            let target = index + offset
            guard key.macro.indices.contains(index), key.macro.indices.contains(target) else { return }
            key.macro.swapAt(index, target)
        }
    }

    private func updateMacroStep(id: UUID, transform: (inout MacroStep) -> Void) {
        updateSelectedKey { key in
            guard let idx = key.macro.firstIndex(where: { $0.id == id }) else { return }
            transform(&key.macro[idx])
        }
    }

    private func updateSelectedKey(_ transform: (inout AhaKeyKeyDraft) -> Void) {
        guard let role = selectedPart.keyRole else { return }
        updateCurrentMode { mode in
            var key = mode.key(for: role)
            transform(&key)
            mode.updateKey(key)
        }
    }

    private func updateCurrentMode(_ transform: (inout AhaKeyModeDraft) -> Void) {
        updateMode(selectedMode, transform)
    }

    private func updateMode(_ modeSlot: AhaKeyModeSlot, _ transform: (inout AhaKeyModeDraft) -> Void) {
        var next = studioDraft
        var mode = next.draft(for: modeSlot)
        transform(&mode)
        next.updateMode(mode)
        studioDraft = next
    }

    private func partIsDirty(_ part: AhaKeyStudioPart) -> Bool {
        let current = studioDraft.draft(for: selectedMode)
        let baseline = lastSyncedDraft.draft(for: selectedMode)
        switch part {
        case .key1, .key2, .key3, .key4:
            guard let role = part.keyRole else { return false }
            return current.key(for: role) != baseline.key(for: role)
        case .oledDisplay:
            return !current.oled.hasSameDeviceConfiguration(as: baseline.oled)
        case .lightBar:
            return current.lightBar != baseline.lightBar
        case .toggleSwitch:
            return false
        }
    }

    private func dirtyPartsForCurrentMode() -> Set<AhaKeyStudioPart> {
        Set(AhaKeyStudioPart.allCases.filter(partIsDirty(_:)))
    }

    private func selectOLEDGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: url)
                try OLEDFrameEncoder.validateFrameCount(at: url)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? String(localized: "text.6f738c166db4", defaultValue: "图片文件不符合上传限制。")
                syncStatusMessage = msg
                updateCurrentMode { mode in
                    mode.oled.statusLine = msg
                }
                return
            }
            let frameCount = OLEDFrameEncoder.frameCount(at: url)
            updateCurrentMode { mode in
                mode.oled.localAssetPath = url.path
                mode.oled.statusLine = String(localized: "text.382a9ad04ce6", defaultValue: "已选 \(max(frameCount, 1)) 帧图片预览；写入时将上传到 \(String(describing: selectedMode.title)) 固定分区。")
            }
            syncStatusMessage = String(localized: "text.252ee028b4ad", defaultValue: "已更新 \(String(describing: selectedMode.title)) 的 LCD 预览；写入设备请使用底部通用按钮。")
        }
    }

    private func handleConfigurationModeButton() {
        if isEditingConfiguration {
            finishEditingConfiguration()
        } else {
            enterEditingConfiguration()
        }
    }

    private func installStartAgentFromTopBar() {
        if agentManager.bluetoothConnectionOwner != .agentDaemon {
            agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        }
        if !agentManager.isInstalled || !agentManager.hooksInstalled {
            agentManager.install()
        } else {
            agentManager.start()
        }
    }

    private func enterEditingConfiguration() {
        isTransitioningToKeyboardControl = false
        agentManager.setBluetoothConnectionOwner(.ahaKeyStudio, bleManager: bleManager)
        syncStatusMessage = String(localized: "text.a4bde4fcc9b3", defaultValue: "已进入编辑配置，AhaKey Studio 将临时接管蓝牙。")
    }

    private func finishEditingConfiguration() {
        guard hasUnsyncedChanges else {
            returnToKeyboardControl()
            return
        }

        if bleManager.isConnected && bleManager.commandCharReady {
            syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
        } else {
            syncStatusMessage = String(localized: "text.acc86913a199", defaultValue: "设备连接中，连接成功后将自动同步并返回控制模式…")
            bleManager.userInitiatedConnect()
            waitForConnectionThenSync()
        }
    }

    private func writeToKeyboard() {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: false, showResultAlert: true)
    }

    private func completeEditingAfterSuccessfulWrite() {
        commitModeNameEdit()
        withAnimation(.easeInOut(duration: 0.18)) {
            isEditingInspector = false
        }
        returnToKeyboardControl()
    }

    // 轮询等待 BLE 连接且命令通道就绪（最多 10 秒），连接后自动同步并返回键盘控制。
    private func waitForConnectionThenSync() {
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if bleManager.isConnected && bleManager.commandCharReady {
                    syncAllModesToDevice(returnToKeyboardControlWhenDone: true)
                    return
                }
            }
            syncStatusMessage = String(localized: "text.1386c39d0d21", defaultValue: "连接超时，本次未写入键盘；已释放蓝牙给 Agent，可再次进入编辑后重试保存。")
            returnToKeyboardControl()
        }
    }

    private func returnToKeyboardControl() {
        isTransitioningToKeyboardControl = true
        agentManager.setBluetoothConnectionOwner(.agentDaemon, bleManager: bleManager)
        syncStatusMessage = String(localized: "text.eac7e1bb374f", defaultValue: "正在恢复键盘控制，Agent 正在连接键盘…")
        monitorAgentReconnect()
    }

    // 返回键盘控制后每 2s 轮询一次 Agent BLE 状态（等待异步 socket 查询完成后再读值），
    // 最多等待 20s；超时后尝试重启 Agent。过渡期结束时清除 isTransitioningToKeyboardControl。
    private func monitorAgentReconnect() {
        Task { @MainActor in
            for i in 0..<10 {
                // 第一次等短些，让 Agent 有时间启动
                let waitMs: UInt64 = i == 0 ? 1_500_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: waitMs)
                agentManager.refresh()
                // 等待 refresh() 内部的异步 socket 查询写回主线程（最多 2.5s timeout）
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if agentManager.isAgentBLEConnected {
                    syncStatusMessage = String(localized: "text.c0b045436621", defaultValue: "已返回键盘控制，Agent 将接管蓝牙。")
                    isTransitioningToKeyboardControl = false
                    return
                }
                // 约 10s 后 Agent 仍未连上，尝试重启
                if i == 2, !agentManager.isAgentBLEConnected {
                    agentManager.start()
                }
            }
            syncStatusMessage = String(localized: "text.c0b045436621", defaultValue: "已返回键盘控制，Agent 将接管蓝牙。")
            isTransitioningToKeyboardControl = false
        }
    }

    private func syncAllModesToDevice(returnToKeyboardControlWhenDone: Bool = false) {
        performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: returnToKeyboardControlWhenDone, showResultAlert: false)
    }

    private func performUnifiedDeviceWrite(returnToKeyboardControlWhenDone: Bool, showResultAlert: Bool) {
        deviceWriteSucceeded = false
        guard bleManager.isConnected && bleManager.commandCharReady else {
            let message = showResultAlert ? String(localized: "text.e9fc015996cd", defaultValue: "设备未连接，请先连接键盘后重试。") : String(localized: "text.bfb114c09694", defaultValue: "设备未连接或命令通道未就绪，当前只保存本地草稿。")
            syncStatusMessage = message
            if showResultAlert {
                writeResultAlertMessage = message
                showsWriteResultAlert = true
            }
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        isSyncing = true
        syncStatusMessage = String(localized: "text.32f0ef7b0de7", defaultValue: "正在准备写入设备…")
        let returnAgent = returnToKeyboardControlWhenDone

        Task { @MainActor in
            do {
                let desiredBrightness = UInt8(max(1, min(100, studioDraft.draft(for: .mode0).lightBar.brightness)))
                syncStatusMessage = String(localized: "text.e0ce2b00fc5b", defaultValue: "正在验证键盘灯效固件…")
                try await bleManager.verifyConfigurableLightingSupport(brightness: desiredBrightness)

                let uploadedOLEDCount = try await uploadChangedOLEDsToDevice()
                var commands = commandsForModes(AhaKeyModeSlot.allCases)
                commands.append((data: AhaKeyCommand.saveConfig(), label: String(localized: "text.3a85c91f4d1f", defaultValue: "保存全部配置到设备")))

                let total = commands.count
                if uploadedOLEDCount > 0 {
                    self.syncStatusMessage = String(localized: "text.e585313ab4e1", defaultValue: "已上传 \(uploadedOLEDCount) 个 LCD 动图，正在写入灯效与键位配置（约 \(total) 条）…")
                } else {
                    self.syncStatusMessage = String(localized: "text.cac7ee71d144", defaultValue: "正在写入灯效与键位配置（约 \(total) 条）…")
                }
                try await self.bleManager.writeCommandsConfirmingResponses(commands)
                // 最后的 0x04 已收到固件 ACK，略等再交还蓝牙。
                try? await Task.sleep(nanoseconds: UInt64(150) * 1_000_000)
                self.deviceWriteSucceeded = true
                self.lastSyncedDraft = self.studioDraft
                self.lastSyncDate = Date()
                self.isSyncing = false
                self.syncStatusMessage = String(localized: "text.0f581ce69ece", defaultValue: "已全部写入设备并保存（所有命令已确认）。")
                if showResultAlert {
                    self.writeResultAlertMessage = String(localized: "text.d0656c4c7791", defaultValue: "配置已成功写入键盘，并收到固件确认。")
                    self.showsWriteResultAlert = true
                }
                if returnAgent {
                    self.returnToKeyboardControl()
                }
            } catch {
                let message = String(localized: "text.70653ba41b82", defaultValue: "写入键盘失败：\(String(describing: error.localizedDescription))")
                self.isSyncing = false
                self.syncStatusMessage = message
                if showResultAlert {
                    self.writeResultAlertMessage = message
                    self.showsWriteResultAlert = true
                }
            }
        }
    }

    private func uploadChangedOLEDsToDevice() async throws -> Int {
        var uploadCount = 0

        for mode in AhaKeyModeSlot.allCases {
            let draft = studioDraft.draft(for: mode)
            guard let assetPath = draft.oled.localAssetPath else { continue }

            let baseline = lastSyncedDraft.draft(for: mode).oled
            let deviceFrameCount = bleManager.keyboardPictureStates[mode.rawValue]?.frameCount ?? 0
            guard !draft.oled.hasSameDeviceConfiguration(as: baseline) || deviceFrameCount == 0 else { continue }

            let assetURL = URL(fileURLWithPath: assetPath)
            try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
            let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = String(localized: "text.620e674be5cd", defaultValue: "正在上传动图到 \(String(describing: mode.title))…")
            }
            syncStatusMessage = String(localized: "text.9e1f7e3d0dd3", defaultValue: "正在上传 \(String(describing: mode.title)) 的 LCD 动图…")

            let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
            try await bleManager.uploadOLEDFrames(
                frames,
                fps: draft.oled.framesPerSecond,
                mode: UInt8(mode.rawValue),
                startIndex: UInt16(startIndex)
            )

            updateMode(mode) { modeDraft in
                modeDraft.oled.statusLine = String(localized: "text.344fda8b5178", defaultValue: "已上传 \(frames.count) 帧到设备，槽位起点 \(startIndex)；切换模式时会先显示描述，再回到当前模式动图。")
            }
            uploadCount += 1
        }

        return uploadCount
    }

    private func resendCurrentModeToDevice() {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = String(localized: "text.bfb114c09694", defaultValue: "设备未连接或命令通道未就绪，当前只保存本地草稿。")
            return
        }

        applyCursorRejectMacroSelfHealIfNeeded()
        var commands = commandsForModes([selectedMode])
        commands.append((data: AhaKeyCommand.saveConfig(), label: String(localized: "text.875de9191ee5", defaultValue: "保存 \(String(describing: selectedMode.title)) 当前配置")))

        isSyncing = true
        syncStatusMessage = String(localized: "text.dca993093a7c", defaultValue: "正在写入 \(String(describing: selectedMode.title))…")
        Task { @MainActor in
            do {
                let desiredBrightness = UInt8(max(1, min(100, currentModeDraft.lightBar.brightness)))
                try await bleManager.verifyConfigurableLightingSupport(brightness: desiredBrightness)
                try await bleManager.writeCommandsConfirmingResponses(commands)
                self.lastSyncDate = Date()
                self.isSyncing = false
                self.syncStatusMessage = String(localized: "text.520bc9617617", defaultValue: "已重新写入 \(String(describing: self.selectedMode.title))（固件已确认）。")
            } catch {
                self.isSyncing = false
                self.syncStatusMessage = String(localized: "text.70653ba41b82", defaultValue: "写入键盘失败：\(String(describing: error.localizedDescription))")
            }
        }
    }

    /// Cursor 档「取消键」若仍为默认 ⌫ 却残留宏，同步会走 0x74 而非单键。清掉误残留宏并与迁移逻辑一致。
    private func applyCursorRejectMacroSelfHealIfNeeded() {
        var next = studioDraft
        var m1 = next.draft(for: .mode1)
        var reject = m1.key(for: .reject)
        let defaultR = AhaKeyModeDraft.default(for: .mode1).key(for: .reject)
        guard !reject.macro.isEmpty, reject.shortcut == defaultR.shortcut else { return }
        reject.macro = []
        m1.updateKey(reject)
        next.updateMode(m1)
        studioDraft = next
    }

    private func commandsForModes(_ modes: [AhaKeyModeSlot]) -> [(data: Data, label: String)] {
        var commands: [(data: Data, label: String)] = []

        for mode in modes {
            let draft = studioDraft.draft(for: mode)
            for role in AhaKeyKeyRole.allCases {
                let key = draft.key(for: role)
                let keyIndex = UInt8(role.rawValue)
                let modeByte = UInt8(mode.rawValue)

                if key.usesMacro {
                    // 固件对 0x73 快捷键、0x74 宏是分层存储的；从「快捷键」改「宏」时须先清掉旧快捷键，否则会残留。
                    commands.append((
                        data: AhaKeyCommand.setKeyMapping(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            hidCodes: []
                        ),
                        label: String(localized: "text.ee22a1baf13c", defaultValue: "清除 \(String(describing: mode.title)) \(String(describing: key.title)) 快捷键层（将写入宏）")
                    ))
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: key.macro.flattenedBytes
                        ),
                        label: String(localized: "text.624a01c14a8b", defaultValue: "写入 \(String(describing: mode.title)) \(String(describing: key.title)) 宏: \(String(describing: key.macro.displaySummary))")
                    ))
                } else {
                    // 从「宏」改「快捷键 / 无键」时须先发空 0x74，否则设备可能仍走旧宏（Cursor/其它 mode 上表现为改键不生效）。
                    commands.append((
                        data: AhaKeyCommand.setKeyMacro(
                            mode: modeByte,
                            keyIndex: keyIndex,
                            macroData: []
                        ),
                        label: String(localized: "text.a9f3bd520799", defaultValue: "清除 \(String(describing: mode.title)) \(String(describing: key.title)) 宏层（将写入快捷键）")
                    ))
                    if !key.shortcut.hidCodes.isEmpty {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: key.shortcut.hidCodes
                            ),
                            label: String(localized: "text.ef2b5cec9027", defaultValue: "写入 \(String(describing: mode.title)) \(String(describing: key.title)) 快捷键: \(String(describing: key.shortcut.displayLabel))")
                        ))
                    } else {
                        commands.append((
                            data: AhaKeyCommand.setKeyMapping(
                                mode: modeByte,
                                keyIndex: keyIndex,
                                hidCodes: []
                            ),
                            label: String(localized: "text.49f36f9c5441", defaultValue: "清除 \(String(describing: mode.title)) \(String(describing: key.title)) 快捷键")
                        ))
                    }
                }

                let sanitizedDescription = key.description.sanitizedASCII(maxLength: 20)
                commands.append((
                    data: AhaKeyCommand.setKeyDescription(
                        mode: UInt8(mode.rawValue),
                        keyIndex: keyIndex,
                        text: key.description
                    ),
                    label: String(localized: "text.b0c65da11ebc", defaultValue: "写入 \(String(describing: mode.title)) \(String(describing: key.title)) 描述: \(String(describing: sanitizedDescription.isEmpty ? String(localized: "text.f0bf4574ce25", defaultValue: "空白") : sanitizedDescription))")
                ))
            }
        }

        for mode in modes {
            let lb = studioDraft.draft(for: mode).lightBar
            let effects = IDEState.allCases.map { lb.effect(for: $0).firmwareIndex }
            commands.append((
                AhaKeyCommand.setLightMapping(mode: UInt8(mode.rawValue), stateEffects: effects),
                String(localized: "text.8a09947b8999", defaultValue: "灯效映射 \(String(describing: mode.title))")
            ))
        }

        let brightness = UInt8(studioDraft.draft(for: modes[0]).lightBar.brightness)
        commands.append((AhaKeyCommand.setBrightness(brightness), String(localized: "text.1bf4726f8484", defaultValue: "亮度 \(String(describing: brightness))%")))

        return commands
    }

    /// 首次连接键盘后自动把 bundle 默认 GIF 推到没有上传过的 mode slot。
    /// 触发时机：bleManager.keyboardPictureStates 四个 mode 都查回来之后
    /// （由 .onChange(of: bleManager.keyboardPictureStates) 调度）。
    /// 守卫：
    /// - 只上传 picLength==0（slot 完全空）的 mode；非 0 视为用户已自定义或固件出厂图
    /// - 只在 draft 的 localAssetPath 仍指向 bundle 默认（用户没手动换过）时上传
    /// - 每次连接只跑一次（oledAutoSyncDoneForConnection 标志位由 .onChange(isConnected) 重置）
    private func autoSyncDefaultOLEDsIfNeeded() async {
        guard bleManager.isConnected else { return }
        // 四个 mode 全部 0x83 查询回来才动手，避免半截判断把已上传 slot 当成空
        guard bleManager.keyboardPictureStates.count == AhaKeyModeSlot.allCases.count else { return }

        for mode in AhaKeyModeSlot.allCases {
            guard let state = bleManager.keyboardPictureStates[mode.rawValue] else { continue }
            guard state.frameCount == 0 else { continue }
            guard let bundledPath = DefaultOLEDAssets.bundledAssetPath(for: mode) else { continue }
            let draft = studioDraft.draft(for: mode)
            guard let drafPath = draft.oled.localAssetPath,
                  DefaultOLEDAssets.isBundledPath(drafPath) else { continue }

            let assetURL = URL(fileURLWithPath: bundledPath)
            do {
                try OLEDFrameEncoder.validateGIFSourceFileSize(at: assetURL)
                let frames = try OLEDFrameEncoder.frames(fromGIFAt: assetURL)
                let startIndex = try await resolveOLEDUploadStartIndex(for: mode, frameCount: frames.count)
                try await bleManager.uploadOLEDFrames(
                    frames,
                    fps: draft.oled.framesPerSecond,
                    mode: UInt8(mode.rawValue),
                    startIndex: UInt16(startIndex)
                )
                updateMode(mode) { m in
                    m.oled.statusLine = String(localized: "text.debf58659f92", defaultValue: "已自动同步默认动图（\(frames.count) 帧）。")
                }
            } catch {
                syncStatusMessage = String(localized: "text.66d0e584131e", defaultValue: "\(String(describing: mode.title)) 默认动图自动同步失败: \(String(describing: error.localizedDescription))")
            }
        }
    }

    private func resolveOLEDUploadStartIndex(for targetMode: AhaKeyModeSlot, frameCount: Int) async throws -> Int {
        guard frameCount <= AhaKeyCommand.oledMaxFramesPerMode else {
            throw OLEDUploadError.tooManyFrames(max: AhaKeyCommand.oledMaxFramesPerMode)
        }

        _ = try? await bleManager.readPictureState(mode: UInt8(targetMode.rawValue))
        return Int(AhaKeyCommand.oledStartIndex(forMode: UInt8(targetMode.rawValue)))
    }

    private func canPlacePictureRange(
        start: Int,
        count: Int,
        occupiedRegions: [(start: Int, end: Int)],
        maxCapacity: Int
    ) -> Bool {
        let end = start + count
        guard start >= 0, end <= maxCapacity else { return false }
        return occupiedRegions.allSatisfy { region in
            end <= region.start || start >= region.end
        }
    }

    private func findFreePictureSpace(
        occupiedRegions: [(start: Int, end: Int)],
        neededCount: Int,
        maxCapacity: Int
    ) -> Int? {
        guard !occupiedRegions.isEmpty else { return 0 }

        if occupiedRegions[0].start >= neededCount {
            return 0
        }

        for index in 0 ..< (occupiedRegions.count - 1) {
            let gapStart = occupiedRegions[index].end
            let gapEnd = occupiedRegions[index + 1].start
            if gapEnd - gapStart >= neededCount {
                return gapStart
            }
        }

        let lastEnd = occupiedRegions.last?.end ?? 0
        if lastEnd + neededCount <= maxCapacity {
            return lastEnd
        }

        return nil
    }

    private func lightEffectBinding(for state: IDEState) -> Binding<LightEffectStyle> {
        Binding(
            get: { currentModeDraft.lightBar.effect(for: state) },
            set: { newEffect in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                if let idx = mode.lightBar.stateMappings.firstIndex(where: { $0.state == state }) {
                    mode.lightBar.stateMappings[idx].effect = newEffect
                }
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                lightBarPreview = state
                previewLightEffect(newEffect)
            }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(currentModeDraft.lightBar.brightness) },
            set: { newValue in
                var draft = studioDraft
                var mode = draft.draft(for: selectedMode)
                mode.lightBar.brightness = Int(newValue)
                draft.updateMode(mode)
                studioDraft = draft
                AhaKeyStudioStore.save(studioDraft)
                previewBrightness(Int(newValue))
            }
        )
    }

    private func previewLightEffect(for state: IDEState) {
        previewLightEffect(currentModeDraft.lightBar.effect(for: state))
    }

    private func previewLightEffect(_ effect: LightEffectStyle) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = String(localized: "text.163d73c575b7", defaultValue: "已更新虚拟灯效预览；连接键盘后可预览到设备。")
            return
        }
        guard bleManager.supportsConfigurableLighting != false else {
            syncStatusMessage = String(localized: "text.2b9074c1614f", defaultValue: "当前是旧协议固件，0x91 会假返回成功但不改灯；请先刷新固件。")
            return
        }
        bleManager.previewLightEffect(effect.firmwareIndex)
        syncStatusMessage = String(localized: "text.b0170a37f070", defaultValue: "正在预览灯效：\(String(describing: effect.title))。")
    }

    private func previewBrightness(_ value: Int) {
        guard bleManager.isConnected && bleManager.commandCharReady else {
            syncStatusMessage = String(localized: "text.456791323dd6", defaultValue: "已更新亮度为 \(String(describing: value))%；连接键盘后可预览到设备。")
            return
        }
        guard bleManager.supportsConfigurableLighting != false else {
            syncStatusMessage = String(localized: "text.b998c3bc4962", defaultValue: "当前是旧协议固件，亮度不会写入；请先刷新固件。")
            return
        }
        bleManager.setBrightness(UInt8(max(1, min(100, value))))
        syncStatusMessage = String(localized: "text.e05324c623c9", defaultValue: "正在预览灯光强度：\(String(describing: value))% 。")
    }

    private func infoPill(title: String, subtitle: String, accent: Color, width: CGFloat = 86) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func manualCallout(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }

    private var nativeSpeechPermissionsReady: Bool {
        nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private var startupPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func scheduleStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
        bleManager.refreshBluetoothAuthorization()
        voiceRelay.refreshPermissions(deferredTCCRequery: true)
        nativeSpeech.refreshPermissions(deferredTCCRequery: true)
    }

    private func refreshStartupPermissionOnboarding() {
        voiceRelay.showsPermissionOnboarding = false
    }
}

private struct VoicePermissionOnboardingSheet: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @ObservedObject var voiceRelay: VoiceRelayService
    @ObservedObject var nativeSpeech: NativeSpeechTranscriptionService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "text.e5a98ad72b25", defaultValue: "新手权限引导"))
                .font(.system(size: 24, weight: .semibold))

            Text(String(localized: "text.033845a48f37", defaultValue: "AhaKey Studio 首次使用需要完成几项系统授权：连接键盘需要蓝牙，后台接管语音键需要输入监控与辅助功能，macOS 原生语音需要麦克风、语音转写、Siri 与听写。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(title: String(localized: "text.aa86faacd6fe", defaultValue: "蓝牙"), granted: bleManager.bluetoothPermissionGranted && bleManager.bluetoothPoweredOn, detail: bleManager.bluetoothPermissionGranted ? String(localized: "text.53d0af2fae78", defaultValue: "打开系统蓝牙，用于发现、连接和同步 AhaKey 键盘。") : String(localized: "text.f2bd4d367bd4", defaultValue: "在「隐私与安全性 > 蓝牙」中允许 AhaKey Studio 使用蓝牙。"))
                permissionRow(title: String(localized: "text.714cac30e2ff", defaultValue: "麦克风"), granted: nativeSpeech.microphoneGranted, detail: String(localized: "text.7d51fe069318", defaultValue: "允许 AhaKey Studio 使用苹果原生语音采集。"))
                permissionRow(title: String(localized: "text.dc4d60da1bcd", defaultValue: "语音转写"), granted: nativeSpeech.speechRecognitionGranted, detail: String(localized: "text.e3cc79f00536", defaultValue: "允许 AhaKey Studio 使用苹果原生语音识别。"))
                permissionRow(title: "Siri", granted: nativeSpeech.siriEnabled, detail: String(localized: "text.74cdf124f592", defaultValue: "在「系统设置 > Siri 与聚焦」里开启 Siri，供 macOS 原生语音能力使用。"))
                permissionRow(title: String(localized: "text.a44d14888ce8", defaultValue: "听写"), granted: nativeSpeech.dictationEnabled, detail: String(localized: "text.fa48dd75aff1", defaultValue: "在「系统设置 > 键盘 > 听写」里开启听写，保证系统语音组件完整可用。"))
                permissionRow(title: String(localized: "text.b8f88aeead15", defaultValue: "辅助功能"), granted: voiceRelay.accessibilityGranted, detail: String(localized: "text.ed0b6b0e3eef", defaultValue: "允许 AhaKey Studio 把语音键转换成苹果原生转写或 Fn/Globe。"))
                permissionRow(title: String(localized: "text.fc22bc8bea45", defaultValue: "输入监控"), granted: voiceRelay.inputMonitoringGranted, detail: String(localized: "text.8ecb0d8fd20c", defaultValue: "允许 AhaKey Studio 在后台监听实体语音键；设置完成后通常需要退出并重新打开。"))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "text.1afa0132c539", defaultValue: "授权步骤"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(localized: "text.5fb7cd34cc29", defaultValue: "1. 点「现在申请权限」，按系统弹窗允许蓝牙、麦克风和语音转写。"))
                Text(String(localized: "text.75149c8fbfbb", defaultValue: "2. 自动打开系统设置后，依次开启 Siri、听写、辅助功能。"))
                Text(String(localized: "text.b89d49b66712", defaultValue: "3. 最后开启输入监控；系统提示重启时退出并重新打开。"))
                Text(String(localized: "text.38b6b944c2fc", defaultValue: "4. 回到这里点「我已完成，重新检查」继续体验输入。"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(String(localized: "text.c18edf8127c9", defaultValue: "若系统里已勾选允许，本应用仍显示未开启：请完全退出 AhaKey Studio 并再启动一次。输入监控、辅助功能等常按进程生效，只点「重新检查」或从后台切回，有时读到的仍是旧状态，重启后即可与系统设置一致。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(localized: "text.b200d50294b2", defaultValue: "外发 / DMG / Xcode：默认正式包在系统「隐私与安全性」里显示为「AhaKey Studio」；用 Xcode 以 Debug 运行本工程时显示为「AhaKey Studio（调试）」，请按名称分别授权。路径或签名不同也会被系统当成另一款 App。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "text.12dfdeea7bf9", defaultValue: "蓝牙 \(String(describing: bleManager.bluetoothPermissionGranted ? (bleManager.bluetoothPoweredOn ? String(localized: "text.8a4ef3e48e4e", defaultValue: "已开启") : String(localized: "text.4f478c062862", defaultValue: "已授权但蓝牙关闭")) : String(localized: "text.94bc3d40defe", defaultValue: "未授权")))"))
                Text(voiceRelay.lastPermissionCheckSummary)
                Text(nativeSpeech.lastPermissionCheckSummary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(String(localized: "text.773d69c46387", defaultValue: "现在申请权限")) {
                    requestPermissionsThenOpenPrivacySettingsIfNeeded(
                        bleManager: bleManager,
                        voiceRelay: voiceRelay,
                        nativeSpeech: nativeSpeech
                    )
                }
                .buttonStyle(.borderedProminent)

                Button(String(localized: "text.8f617293e166", defaultValue: "我已完成，重新检查")) {
                    bleManager.refreshBluetoothAuthorization()
                    voiceRelay.refreshPermissions(deferredTCCRequery: true)
                    nativeSpeech.refreshPermissions(deferredTCCRequery: true)
                }
                .buttonStyle(.bordered)

                RestartToApplyPermissionsButton(title: String(localized: "text.a24f07c29eca", defaultValue: "退出并重新打开"))

                if !allPermissionsReady {
                    Button(String(localized: "text.0407dbdaf0dd", defaultValue: "打开系统设置")) {
                        openCombinedVoicePrivacySettingsURL()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(String(localized: "text.99845832ed7f", defaultValue: "稍后再说")) {
                    voiceRelay.dismissPermissionOnboarding()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            if allPermissionsReady {
                Text(String(localized: "text.86122d1df14b", defaultValue: "新手权限已经齐了。关闭这个弹窗后，AhaKey Studio 可以连接键盘、后台监听语音键，macOS 原生语音也可以正常使用。"))
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text(String(localized: "text.129b46d63819", defaultValue: "仍有权限未开启。请按上方状态逐项处理，全部变为绿色后再关闭弹窗。"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: voiceRelay.inputMonitoringGranted) { _ in
            closeIfReady()
        }
        .onChange(of: voiceRelay.accessibilityGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPermissionGranted) { _ in
            closeIfReady()
        }
        .onChange(of: bleManager.bluetoothPoweredOn) { _ in
            closeIfReady()
        }
    }

    private func closeIfReady() {
        guard allPermissionsReady else { return }
        voiceRelay.dismissPermissionOnboarding()
        dismiss()
    }

    private var allPermissionsReady: Bool {
        bleManager.bluetoothPermissionGranted &&
            bleManager.bluetoothPoweredOn &&
            voiceRelay.inputMonitoringGranted &&
            voiceRelay.accessibilityGranted &&
            nativeSpeech.microphoneGranted &&
            nativeSpeech.speechRecognitionGranted &&
            nativeSpeech.siriEnabled &&
            nativeSpeech.dictationEnabled
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(granted ? String(localized: "text.8a4ef3e48e4e", defaultValue: "已开启") : String(localized: "text.3cffa9757b69", defaultValue: "未开启"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct VoicePresetPicker: View {
    let selectedPreset: VoicePreset
    let onSelect: (VoicePreset) -> Void

    private let visiblePresets = VoicePreset.visibleCases
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(visiblePresets) { preset in
                Button {
                    if preset.availableInV1 {
                        onSelect(preset)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(preset.title)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            if !preset.availableInV1 {
                                Text(String(localized: "text.78c33fbf0e2a", defaultValue: "开发中"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(cardFill(for: preset))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(cardStroke(for: preset), lineWidth: preset == selectedPreset ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!preset.availableInV1)
            }
        }
    }

    private func cardFill(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return Color.accentColor.opacity(0.16)
        }
        if !preset.availableInV1 {
            return Color(nsColor: .controlBackgroundColor).opacity(0.65)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func cardStroke(for preset: VoicePreset) -> Color {
        if preset == selectedPreset {
            return .accentColor
        }
        return Color.black.opacity(0.08)
    }
}

private struct ShortcutBindingEditor: View {
    @Binding var shortcut: ShortcutBinding
    @State private var isRecordingPrimaryKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "text.ba0e2ff8201b", defaultValue: "修饰键"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Toggle(isOn: modifierBinding(modifier)) {
                            Text(modifier.symbol)
                                .font(.system(.headline, design: .rounded))
                        }
                        .toggleStyle(.button)
                        .help(modifier.title)
                    }
                    if !shortcut.modifiers.isEmpty {
                        Button(String(localized: "text.e054d948e730", defaultValue: "清除修饰键")) {
                            var next = shortcut
                            next.modifiers = []
                            shortcut = next
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "text.ecfc9d2e0157", defaultValue: "主键"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PrimaryKeyInputField(
                    shortcut: $shortcut,
                    isRecording: $isRecordingPrimaryKey
                )
            }

            if !shortcut.modifiers.isEmpty {
                Text(String(localized: "text.14a0e2a6c959", defaultValue: "当前为组合键（\(String(describing: shortcut.displayLabel))）。若你只想发单键 Enter，勿打开 ⌘/⌃ 等，或点「清除修饰键」后再选 Enter。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modifierBinding(_ modifier: ShortcutModifier) -> Binding<Bool> {
        Binding(
            get: { shortcut.modifiers.contains(modifier) },
            set: { on in
                var next = shortcut
                next.setModifier(modifier, enabled: on)
                shortcut = next
            }
        )
    }

}

private struct PrimaryKeyInputField: View {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool

    private var displayText: String {
        shortcut.keyCode == 0 ? String(localized: "text.de23fe6cb588", defaultValue: "直接按下键盘快捷键即可") : HIDUsage.name(for: shortcut.keyCode)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isRecording ? Color.accentColor : Color.black.opacity(0.12), lineWidth: isRecording ? 1.5 : 1)
                )

            KeyCaptureOverlay(
                shortcut: $shortcut,
                isRecording: $isRecording,
                onActivate: {
                    isRecording = true
                }
            )
            .padding(.trailing, 38)

            HStack(spacing: 8) {
                Image(systemName: isRecording ? "keyboard.badge.ellipsis" : "keyboard")
                    .foregroundStyle(isRecording ? Color.accentColor : Color.secondary)
                Text(displayText)
                    .font(.callout)
                    .foregroundStyle(shortcut.keyCode == 0 && !isRecording ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer()

                Menu {
                    Button(String(localized: "text.de23fe6cb588", defaultValue: "直接按下键盘快捷键即可")) {
                        shortcut = ShortcutBinding()
                        isRecording = false
                    }
                    Divider()
                    ForEach(HIDUsage.allOptions, id: \.code) { option in
                        Button(option.name) {
                            var next = shortcut
                            next.keyCode = option.code
                            shortcut = next
                            isRecording = false
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "text.8d879c190252", defaultValue: "展开下拉列表"))
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .help(String(localized: "text.52eb493edd1c", defaultValue: "直接按键设置主键，点击箭头展开下拉列表。"))
    }
}

private struct KeyCaptureOverlay: NSViewRepresentable {
    @Binding var shortcut: ShortcutBinding
    @Binding var isRecording: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        configure(nsView)
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    private func configure(_ view: KeyCaptureNSView) {
        view.onBeginRecording = {
            onActivate()
            isRecording = true
        }
        view.onCapture = { event in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: event.keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(
                modifiers: shortcutModifiers(from: event.modifierFlags),
                keyCode: hidCode
            )
            isRecording = false
        }
        view.onCaptureModifier = { keyCode in
            guard let hidCode = HIDUsage.hidCode(forMacKeyCode: keyCode) else {
                NSSound.beep()
                isRecording = false
                return
            }
            shortcut = ShortcutBinding(modifiers: [], keyCode: hidCode)
            isRecording = false
        }
    }

    final class KeyCaptureNSView: NSView {
        var onBeginRecording: (() -> Void)?
        var onCapture: ((NSEvent) -> Void)?
        var onCaptureModifier: ((UInt16) -> Void)?
        private var pendingModifierCapture: DispatchWorkItem?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onBeginRecording?()
        }

        override func keyDown(with event: NSEvent) {
            pendingModifierCapture?.cancel()
            pendingModifierCapture = nil
            onCapture?(event)
        }

        override func flagsChanged(with event: NSEvent) {
            onBeginRecording?()
            pendingModifierCapture?.cancel()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control)
                || flags.contains(.option)
                || flags.contains(.shift)
                || flags.contains(.command)
                || flags.contains(.capsLock)
                || flags.contains(.function)
            else {
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.onCaptureModifier?(event.keyCode)
                self?.pendingModifierCapture = nil
            }
            pendingModifierCapture = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }
    }
}

private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> [ShortcutModifier] {
    var modifiers: [ShortcutModifier] = []
    if flags.contains(.control) { modifiers.append(.control) }
    if flags.contains(.option) { modifiers.append(.option) }
    if flags.contains(.shift) { modifiers.append(.shift) }
    if flags.contains(.command) { modifiers.append(.command) }
    return modifiers
}

private struct CanvasKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.12, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private struct AhaKeyKeyboardCanvasView: View {
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

    private func openNativeSpeechPrivacySettings() {
        openNativeSpeechPrivacySettingsURL()
    }
}

private struct AnimatedGIFView: View {
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
private final class AnimatedGIFPlayer: ObservableObject {
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

private func openNativeSpeechPrivacySettingsURL() {
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy"
    ]

    openFirstAvailableSystemSettingsURL(candidates)
}

/// 输入监控 / 辅助功能 / 麦克风和语音转写：系统在「已拒绝」或部分版本下不会再弹权限窗。主动申请后打开「隐私与安全性」相关页，保证有可操作反馈。
@MainActor
private func openCombinedVoicePrivacySettingsURL() {
    // 勿用未文档化的 `x-apple.systemsettings` + `.extension` 等组合；在部分系统上会被当成「文稿」，
    // 连续弹出「在 App Store 搜索… / 选取应用程序」而非进入设置。
    let candidates = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.security?Privacy",
    ]
    if openFirstAvailableSystemSettingsURL(candidates) { return }
    let appPaths = [
        "/System/Applications/System Settings.app",
        "/System/Library/CoreServices/Applications/System Settings.app",
        "/System/Applications/System Preferences.app",
    ]
    for path in appPaths where FileManager.default.fileExists(atPath: path) {
        if NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            return
        }
    }
}

@discardableResult
private func openFirstAvailableSystemSettingsURL(_ candidates: [String]) -> Bool {
    for candidate in candidates {
        guard let url = URL(string: candidate) else { continue }
        if NSWorkspace.shared.open(url) {
            return true
        }
    }
    return false
}

@MainActor
private func openFirstMissingVoicePermissionSettings(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService
) {
    if !bleManager.bluetoothPermissionGranted || !bleManager.bluetoothPoweredOn {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]) { return }
    }
    if !nativeSpeech.microphoneGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]) { return }
    }
    if !nativeSpeech.speechRecognitionGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]) { return }
    }
    if !nativeSpeech.siriEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Siri-Settings.extension"]) { return }
    }
    if !nativeSpeech.dictationEnabled {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]) { return }
    }
    if !voiceRelay.accessibilityGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]) { return }
    }
    if !voiceRelay.inputMonitoringGranted {
        if openFirstAvailableSystemSettingsURL(["x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]) { return }
    }
    openCombinedVoicePrivacySettingsURL()
}

/// 先走系统 API 申请；随后在桌面端打开「隐私与安全性」相关页。输入监控 / 辅助功能在多数 macOS 版本上**不会**像 iOS 那样弹窗，麦克风和语音在「已选择过」后也不再弹窗，因此必须配合系统设置界面。
@MainActor
private func requestPermissionsThenOpenPrivacySettingsIfNeeded(
    bleManager: AhaKeyBLEManager,
    voiceRelay: VoiceRelayService,
    nativeSpeech: NativeSpeechTranscriptionService,
    delay: TimeInterval = 0.45
) {
    bleManager.refreshBluetoothAuthorization()
    voiceRelay.refreshPermissions(requestIfNeeded: true)
    nativeSpeech.refreshPermissions(requestIfNeeded: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        bleManager.refreshBluetoothAuthorization()
        openFirstMissingVoicePermissionSettings(bleManager: bleManager, voiceRelay: voiceRelay, nativeSpeech: nativeSpeech)
    }
}

/// 先启动一个延迟重开助手，再退出当前进程。不要在旧进程仍存活时 `open -n`：
/// AppDelegate 有单实例保护，新实例会发现旧实例还在并立即退出，造成"新程序闪退、旧程序不关"。
private func relaunchApplicationForPermissionRefresh() {
    let bundlePath = Bundle.main.bundleURL.path
    let script = "sleep 0.8; /usr/bin/open \(shellQuoted(bundlePath))"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    do {
        try process.run()
    } catch {
        // 即使自动重开助手启动失败，也要让当前进程正常退出；用户可手动再打开。
    }

    NSApp.windows.forEach { $0.close() }
    NSApp.terminate(nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if NSApp.isRunning {
            exit(0)
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@MainActor
private func activateAhaKeyWindowForTextInput() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.keyWindow?.makeKeyAndOrderFront(nil)
    NSApp.mainWindow?.makeKeyAndOrderFront(nil)
}

/// 在系统「隐私与安全性」中改完权限后，用确认框引导用户：退出后由 `open -n` 自动拉起同一份 .app。
private struct RestartToApplyPermissionsButton: View {
    var title: String = String(localized: "text.e9bcfd18cc26", defaultValue: "退出并重新打开…")
    @State private var showConfirm = false

    var body: some View {
        Button(title) { showConfirm = true }
            .buttonStyle(.bordered)
            .help(String(localized: "text.740ba7f9897f", defaultValue: "在系统设置中修改权限后，需重启本应用，检测才会与系统一致。"))
            .alert(String(localized: "text.4064e7b14d3e", defaultValue: "需要重启以刷新权限"), isPresented: $showConfirm) {
                Button(String(localized: "text.2cd0f3be8738", defaultValue: "取消"), role: .cancel) {}
                Button(String(localized: "text.700b6c80d954", defaultValue: "立即重启")) { relaunchApplicationForPermissionRefresh() }
            } message: {
                Text(String(localized: "text.5c9850140124", defaultValue: "将先退出本应用，再自动重新打开。重新打开后「重新检查权限」会读取最新系统状态。"))
            }
    }
}

private struct DeviceInfoSheetContainer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(spacing: 0) {
            deviceInfoTitleChrome
            sheetScrollView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            activateAhaKeyWindowForTextInput()
        }
    }

    @ViewBuilder
    private var sheetScrollView: some View {
        if #available(macOS 13.0, *) {
            ScrollView {
                sheetFormContent
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                sheetFormContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sheetFormContent: some View {
        DeviceInfoView(bleManager: bleManager)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deviceInfoTitleChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(String(localized: "text.d71c08ca8a99", defaultValue: "设备信息 · Agent"))
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Label(String(localized: "text.3fd47edce45b", defaultValue: "关闭"), systemImage: "xmark.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Divider()
        }
        .layoutPriority(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: 48)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CloudAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var account = CloudAccountManager.shared
    @StateObject private var optimizer = AhaTypeTextOptimizer.shared
    @FocusState private var focusedLoginField: LoginField?

    private enum LoginField {
        case phone
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "text.718ee9ac9a1f", defaultValue: "云端账号 · AhaType"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) { dismiss() }
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if account.isLoggedIn {
                        profileSection
                    } else {
                        loginSection
                    }

                    Divider()

                    ahaTypeSection
                }
                .padding(18)
            }
        }
        .alert(String(localized: "text.a416c44df8a8", defaultValue: "云端账号"), isPresented: Binding(
            get: { account.alertMessage != nil },
            set: { if !$0 { account.alertMessage = nil } }
        )) {
            Button(String(localized: "text.f867f3417859", defaultValue: "好"), role: .cancel) { account.alertMessage = nil }
        } message: {
            Text(account.alertMessage ?? "")
        }
        .onAppear {
            activateAhaKeyWindowForTextInput()
            optimizer.refreshFromDisk()
            if account.isLoggedIn {
                account.refreshProfile()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
            }
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "text.dc57070dc8a7", defaultValue: "登录后可使用 AhaType 云端大模型整理。"))
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(String(localized: "text.6f52cc94db65", defaultValue: "手机号"), text: $account.phone)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .phone)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .phone
                }
                .onSubmit { focusedLoginField = .password }

            SecureField(String(localized: "text.a621ab606db2", defaultValue: "密码"), text: $account.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedLoginField, equals: .password)
                .onTapGesture {
                    activateAhaKeyWindowForTextInput()
                    focusedLoginField = .password
                }
                .onSubmit { account.login() }

            Toggle(String(localized: "text.6d1d717a83e1", defaultValue: "记住密码"), isOn: $account.rememberPassword)

            HStack(spacing: 10) {
                Button(String(localized: "text.1e2df9c3075a", defaultValue: "登录")) { account.login() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button(String(localized: "text.c4fb62202bad", defaultValue: "注册")) { account.register() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.profileSummary)
                .font(.callout)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                quotaRow(title: String(localized: "text.fd7b67c923cd", defaultValue: "每日"), value: account.quotaText("daily"))
                quotaRow(title: String(localized: "text.92845d3b531d", defaultValue: "每周"), value: account.quotaText("weekly"))
                quotaRow(title: String(localized: "text.68b21af949de", defaultValue: "每月"), value: account.quotaText("monthly"))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack(spacing: 10) {
                Button(String(localized: "text.aee887434131", defaultValue: "刷新")) { account.refreshProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(account.isBusy)
                Button(String(localized: "text.e0351ba25410", defaultValue: "切换账号")) {
                    account.prepareForRelogin()
                    focusedLoginField = .phone
                }
                .buttonStyle(.bordered)
                .disabled(account.isBusy)
                Button(String(localized: "text.3ab8cc15939f", defaultValue: "退出登录")) { account.logout() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            rechargeSection

            HStack(spacing: 10) {
                TextField(String(localized: "text.b08f73bbb6c1", defaultValue: "免费券兑换码"), text: $account.couponCode)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "text.d094e6cb7e78", defaultValue: "兑换")) { account.redeemCoupon() }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
            }

            Text(account.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rechargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "text.f5a9ac8bd0ff", defaultValue: "充值订阅"))
                .font(.callout.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(CloudRechargePlan.allCases) { plan in
                    Button {
                        account.createWechatOrder(plan: plan)
                    } label: {
                        VStack(spacing: 3) {
                            Text(plan.title)
                                .font(.caption.weight(.semibold))
                            Text(account.priceText(for: plan))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(plan.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(account.isBusy)
                }
            }

            if let order = account.paymentOrder {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = makeQRCodeImage(from: order.paymentURL) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 132, height: 132)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(order.plan.title) · \(order.amountText)")
                                .font(.caption.weight(.semibold))
                            Text(String(localized: "text.3763dc74a6c4", defaultValue: "微信扫码完成支付，支付成功后会自动刷新额度。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "text.cac38006264b", defaultValue: "订单：\(String(describing: order.outTradeNo))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Text(String(localized: "text.8944434aa7aa", defaultValue: "状态：\(String(describing: order.status))"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(String(localized: "text.a605eea66e44", defaultValue: "复制支付链接")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(order.paymentURL, forType: .string)
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "text.1d57f966aaaa", defaultValue: "刷新到账")) {
                            account.refreshCurrentPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                        .disabled(account.isBusy)

                        Button(String(localized: "text.be792396ebfb", defaultValue: "关闭订单")) {
                            account.clearPaymentOrder()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var ahaTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { optimizer.isEnabled },
                set: { optimizer.setEnabled($0) }
            )) {
                Text(String(localized: "text.48b80dc3b758", defaultValue: "启用 AhaType 云端整理"))
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)

            Text(String(localized: "text.fd48629cd315", defaultValue: "开启后，macOS 原生语音转写完成后会先请求云端整理，再粘贴整理后的文本。未登录、过期或网络失败时会自动回退原始转写。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(optimizer.lastQuotaSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func quotaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeQRCodeImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct HotspotChrome: ViewModifier {
    let part: AhaKeyStudioPart
    let selectedPart: AhaKeyStudioPart
    let dirtyParts: Set<AhaKeyStudioPart>

    func body(content: Content) -> some View {
        let isSelected = selectedPart == part
        content
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    // 非选中时几乎隐形，避免每个 hotspot 都画一圈灰线和邻近元件视觉打架
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.015),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if dirtyParts.contains(part) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .padding(8)
                }
            }
            // 选中态阴影从 10 收到 6，减少向邻近元件溢出的发光半径
            .shadow(color: isSelected ? Color.accentColor.opacity(0.18) : .clear, radius: 6)
    }
}

private struct OLEDMotionPreviewSheet: View {
    let modeTitle: String
    let assetPath: String?
    let fps: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "text.9b0749974bdd", defaultValue: "\(String(describing: modeTitle)) 动图预览"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(String(localized: "text.7b5a955722ce", defaultValue: "这里展示的是你刚选中的 GIF 动图文件。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.92))

                if let assetPath {
                    DraggableAnimatedGIFPreview(path: assetPath, fps: fps)
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: {
                            if #available(macOS 14, *) { "film.stack" } else { "film" }
                        }())
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "text.1f4f655d1c6e", defaultValue: "还没有选择动图"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                        .frame(minWidth: 480, minHeight: 240)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 460)
            .clipped()
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 380)
    }
}

/// 支持鼠标按住拖拽（上下左右）查看大图，避免仅靠滚轮导致横向浏览困难。
private struct DraggableAnimatedGIFPreview: View {
    let path: String
    let fps: Int
    @State private var imageSize = CGSize(width: 480, height: 240)
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            AnimatedGIFView(path: path, fps: fps, maxPixelSize: 1_200)
                .frame(width: imageSize.width, height: imageSize.height)
                .position(
                    x: viewportSize.width / 2 + offset.width,
                    y: viewportSize.height / 2 + offset.height
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let proposed = CGSize(
                                width: dragStartOffset.width + value.translation.width,
                                height: dragStartOffset.height + value.translation.height
                            )
                            offset = clampOffset(proposed, imageSize: imageSize, viewportSize: viewportSize)
                        }
                        .onEnded { _ in
                            dragStartOffset = offset
                        }
                )
                .onAppear {
                    reloadImageSizeAndResetOffset()
                }
                .onChange(of: path) { _ in
                    reloadImageSizeAndResetOffset()
                }
        }
    }

    private func reloadImageSizeAndResetOffset() {
        if let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 {
            imageSize = image.size
        } else {
            imageSize = CGSize(width: 480, height: 240)
        }
        offset = .zero
        dragStartOffset = .zero
    }

    private func clampOffset(_ proposed: CGSize, imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height - viewportSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

// MARK: - 帮助中心（内嵌弹窗）

private enum HelpTopic: String, CaseIterable, Identifiable {
    case overview
    case modes
    case canvas
    case toggleSwitch
    case oled
    case lightBar
    case voice
    case diagnostics
    case faq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "text.a33db5730556", defaultValue: "总览")
        case .modes: return String(localized: "text.54801410237b", defaultValue: "四个 Mode")
        case .canvas: return String(localized: "text.71dfd58830f6", defaultValue: "画布与按键")
        case .toggleSwitch: return String(localized: "text.e599f5852d14", defaultValue: "虚拟拨杆")
        case .oled: return String(localized: "text.7ad42c1f2fc0", defaultValue: "LCD 屏幕")
        case .lightBar: return String(localized: "text.3eaead948521", defaultValue: "灯条颜色")
        case .voice: return String(localized: "text.2fdc91e671fd", defaultValue: "语音输入")
        case .diagnostics: return String(localized: "text.22aa5b3f29c5", defaultValue: "权限诊断")
        case .faq: return String(localized: "text.45a6d115fdfb", defaultValue: "常见问题")
        }
    }

    var iconName: String {
        switch self {
        case .overview: return "sparkles"
        case .modes: return "square.grid.3x1.below.line.grid.1x2"
        case .canvas: return "keyboard"
        case .toggleSwitch: return "switch.2"
        case .oled: return "play.tv"
        case .lightBar: return "rainbow"
        case .voice: return "mic.circle"
        case .diagnostics: return "stethoscope"
        case .faq: return "questionmark.bubble"
        }
    }
}

private struct HelpCenterSheet: View {
    let studioDraft: AhaKeyStudioDraft
    let selectedMode: AhaKeyModeSlot
    @ObservedObject var bleManager: AhaKeyBLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var topic: HelpTopic = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(String(localized: "text.10e0bc8695fc", defaultValue: "AhaKey Studio 帮助中心"))
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(String(localized: "text.c0b3fbff51cc", defaultValue: "完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.thinMaterial)

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 188)
                    .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                ScrollView {
                    contentForTopic
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(topic)
            }
        }
        .frame(width: 880, height: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpTopic.allCases) { t in
                Button {
                    topic = t
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.iconName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)
                        Text(t.title)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(t == topic ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(t == topic ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var contentForTopic: some View {
        switch topic {
        case .overview:      OverviewTopicView()
        case .modes:         ModesTopicView(selectedMode: selectedMode)
        case .canvas:        CanvasTopicView()
        case .toggleSwitch:  ToggleSwitchTopicView(bleManager: bleManager)
        case .oled:          OLEDTopicView(studioDraft: studioDraft, bleManager: bleManager)
        case .lightBar:      LightBarTopicView()
        case .voice:         VoiceTopicView()
        case .diagnostics:   DiagnosticsTopicView()
        case .faq:           FAQTopicView()
        }
    }
}

// MARK: 帮助中心 - 通用排版

private struct HelpTitle: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title).font(.title2.weight(.semibold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }
}

private struct HelpSection: View {
    let title: String
    let text: String

    init(title: String, body text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

private struct HelpNote: View {
    let icon: String
    let tint: Color
    let text: String

    init(_ icon: String, tint: Color = .orange, body text: String) {
        self.icon = icon
        self.tint = tint
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.vertical, 6)
    }
}

private struct HelpSwatch: View {
    let color: Color
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: 帮助中心 - 各章节

private struct OverviewTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "sparkles",
                title: String(localized: "text.a33db5730556", defaultValue: "总览"),
                subtitle: String(localized: "text.94beb9ec8072", defaultValue: "AhaKey Studio 是 AhaKey 小键盘的 macOS 配置中心")
            )

            HelpSection(
                title: String(localized: "text.0ff2622c6c91", defaultValue: "三件套是怎么协同的"),
                body: String(localized: "text.9af02347c77b", defaultValue: "• 主 App（你正在用的）— 看配置、改键位、上传 LCD 动图、查诊断\n• Agent 守护进程 — 后台常驻；监听 IDE 的 Hook（Claude / Cursor / Codex / Kimi），并在 BLE 上向键盘转发当前 AI 状态\n• 键盘固件 — 收到 BLE 状态后驱动灯条颜色、LCD 显示、按键映射")
            )

            HelpSection(
                title: String(localized: "text.deed59fd6a96", defaultValue: "BLE 占用是一道单行道"),
                body: String(localized: "text.c5c71d166fdb", defaultValue: "同一时刻只有一个进程能持有键盘的 BLE 连接：\n• 默认 Agent 占用 → Hook 状态实时上键盘、自动批准链可用\n• 你在画布点「修改」时 → 主 App 临时接管，能上传 LCD 动图、改键位、读图片元信息\n• 点「返回」 → 主 App 释放，Agent 自动接回")
            )

            HelpNote("info.circle.fill", tint: .blue, body: String(localized: "text.aed28418ca4d", defaultValue: "首次连接，可以先打开「权限诊断」过一遍权限项；任何 Hook 不生效的问题大多在权限里。"))
        }
    }
}

private struct ModesTopicView: View {
    let selectedMode: AhaKeyModeSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "square.grid.3x1.below.line.grid.1x2",
                title: String(localized: "text.54801410237b", defaultValue: "四个 Mode"),
                subtitle: String(localized: "text.b138fc821dda", defaultValue: "硬件物理键码 + 软件配置同步切换")
            )

            ForEach(AhaKeyModeSlot.allCases) { mode in
                modeCard(mode)
            }

            HelpNote("hand.tap.fill", tint: .accentColor, body: String(localized: "text.263c52f8c147", defaultValue: "切换方式：键盘上的 Mode 拨杆，或主 App 顶部 Picker，或点画布上的 Mode 按钮。三处任一改动会同步另外两个。"))
        }
    }

    @ViewBuilder
    private func modeCard(_ mode: AhaKeyModeSlot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(mode.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(modeChipColor(mode), in: Capsule())
                Text(mode.name).font(.headline)
                if mode == selectedMode {
                    Text(String(localized: "text.cb62ebd689ee", defaultValue: "当前")).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            Text(mode.subtitle).font(.callout).foregroundStyle(.secondary)
            Text(mode.guidance).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .padding(.bottom, 6)
    }

    private func modeChipColor(_ mode: AhaKeyModeSlot) -> Color {
        switch mode {
        case .mode0: return Color.orange
        case .mode1: return Color.purple
        case .mode2: return Color.green
        case .mode3: return Color.blue
        }
    }
}

private struct CanvasTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "keyboard",
                title: String(localized: "text.71dfd58830f6", defaultValue: "画布与按键"),
                subtitle: String(localized: "text.693b079820a3", defaultValue: "中间那个像键盘的图就是你的小键盘 1:1 镜像，所有元件可点")
            )

            HelpSection(title: String(localized: "text.58b72923f8d8", defaultValue: "六大热区"), body: String(localized: "text.7906523a5dcf", defaultValue: "灯条、LCD 屏幕、Key1（语音）、Key2、Key3、Key4、拨杆。点哪个就在右侧 Inspector 看到那个元件的配置。"))

            VStack(alignment: .leading, spacing: 10) {
                hotspotRow("rainbow", String(localized: "text.23acd5a1da34", defaultValue: "灯条"), String(localized: "text.ac73d57bfbb1", defaultValue: "点亮键盘顶端 8 颗 WS2812 LED；颜色和效果跟随 IDE Hook 状态。"))
                hotspotRow("play.tv", String(localized: "text.7ad42c1f2fc0", defaultValue: "LCD 屏幕"), String(localized: "text.4986959da036", defaultValue: "0.96\" IPS 显示；可上传 GIF 动图（160×80, RGB565）。"))
                hotspotRow("mic", String(localized: "text.eb897bdb5f16", defaultValue: "Key 1 / 语音键"), String(localized: "text.2c91fd0c1dd8", defaultValue: "macOS 原生语音默认 F18；Typeless / 微信的 Fn 触发使用 F19。"))
                hotspotRow("checkmark.circle", String(localized: "text.100837342489", defaultValue: "Key 2 / 通过键"), String(localized: "text.b4457fbbf6d9", defaultValue: "依 Mode 默认：Y / ↵ / ↵。可改成宏序列。"))
                hotspotRow("xmark.circle", String(localized: "text.6ad1e3148913", defaultValue: "Key 3 / 拒绝键"), String(localized: "text.6ed552957f24", defaultValue: "依 Mode 默认：N / ⌫ / Esc。可改成宏序列。"))
                hotspotRow("delete.left", String(localized: "text.416ab6bfcf1e", defaultValue: "Key 4 / 删除键"), String(localized: "text.23b3179f5758", defaultValue: "默认 Backspace，可改任意短按 / 长按。"))
                hotspotRow("switch.2", String(localized: "text.ad80c32c571a", defaultValue: "拨杆"), String(localized: "text.8f8f7a957a96", defaultValue: "auto 批准 vs manual 批准；详见「虚拟拨杆」章节。"))
            }

            HelpNote("hand.point.up.left", tint: .accentColor, body: String(localized: "text.72f36c5de26d", defaultValue: "点完元件 → Inspector 显示「修改」按钮。点「修改」会接管 BLE 进入编辑态；改完点「写入键盘」写入配置，点「返回」退出编辑。"))
        }
    }

    private func hotspotRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct ToggleSwitchTopicView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "switch.2",
                title: String(localized: "text.e599f5852d14", defaultValue: "虚拟拨杆"),
                subtitle: String(localized: "text.0f41fe432c5a", defaultValue: "物理拨杆坏了？或想软件控制？看这里")
            )

            HelpSection(title: String(localized: "text.040a30005714", defaultValue: "两档分别管什么"), body: String(localized: "text.0257222326ac", defaultValue: "• 自动批准（switchState=0）：Hook 拦截每次工具调用 / 命令请求时直接放行\n• 手动批准（switchState=1）：Hook 把决定交回终端，由你手动按 Key2/Key3 通过或拒绝"))

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "text.e023d21e3148", defaultValue: "点画布拨杆触发三件事（不是所有都生效）：")).font(.subheadline.weight(.medium))
                triggerRow(
                    num: "1",
                    title: String(localized: "text.d8dc184af499", defaultValue: "乐观更新画布"),
                    desc: String(localized: "text.241eb9eda60e", defaultValue: "立即翻转画布拨杆位置 + 顶部状态栏；视觉零延迟"),
                    works: true
                )
                triggerRow(
                    num: "2",
                    title: String(localized: "text.f483d3233012", defaultValue: "通知 Agent 设置 userSwitchOverride"),
                    desc: String(localized: "text.8020e151a950", defaultValue: "Hook 的 auto-approve 立即切换到你选的档位。持久化到 UserDefaults，agent 重启仍生效"),
                    works: true
                )
                triggerRow(
                    num: "3",
                    title: String(localized: "text.4ff6d7efb9fb", defaultValue: "软件覆盖拨杆"),
                    desc: String(localized: "text.f2ba72e3303c", defaultValue: "最新固件 0x91 已用于灯效预览；虚拟拨杆只影响 Hook auto-approve，不再写键盘 sw_state。"),
                    works: false,
                    requiresPatch: false
                )
            }

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: String(localized: "text.576389d100d8", defaultValue: "虚拟拨杆不再占用 0x91，避免与最新固件的灯效预览命令冲突。"))

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "text.c01b4c854d09", defaultValue: "现状一览")).font(.subheadline.weight(.medium))
                stateRow(String(localized: "text.fed56bf2774d", defaultValue: "当前生效值"), "\(bleManager.agentSwitchState ?? bleManager.switchState)")
                stateRow(String(localized: "text.53bb6763e0b8", defaultValue: "Agent 端覆盖"), bleManager.agentSwitchState != nil ? String(localized: "text.8416cbba9959", defaultValue: "\(String(describing: bleManager.agentSwitchState!))（覆盖中）") : String(localized: "text.0ff25dfdc89e", defaultValue: "未设置（用键盘真实值）"))
                stateRow(String(localized: "text.107982c200fb", defaultValue: "乐观显示中"), bleManager.optimisticSwitchOverride != nil ? String(localized: "text.e832396f6ae7", defaultValue: "是（等待对齐）") : String(localized: "text.0c70665b6eb6", defaultValue: "否"))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func triggerRow(num: String, title: String, desc: String, works: Bool, requiresPatch: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(works ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.medium))
                    if requiresPatch {
                        Text(String(localized: "text.ad6fbfc3e36a", defaultValue: "需固件支持")).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                    }
                }
                Text(desc).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func stateRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }
}

private struct OLEDTopicView: View {
    let studioDraft: AhaKeyStudioDraft
    @ObservedObject var bleManager: AhaKeyBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "play.tv",
                title: String(localized: "text.7ad42c1f2fc0", defaultValue: "LCD 屏幕"),
                subtitle: String(localized: "text.79110562e28b", defaultValue: "0.96\" IPS · 160×80 · RGB565 · 内置 16 Mbit Flash 存帧")
            )

            HelpSection(title: String(localized: "text.5daf440d1e84", defaultValue: "默认动图（连接即自动同步）"), body: String(localized: "text.12adb701e09d", defaultValue: "Mode 1 → claude_0.gif（出厂内置）\nMode 2 → cursor.gif\nMode 3 → codex.gif\nMode 4 → 预留/自定义\n\n首次连接键盘且发现某个 Mode 的 flash slot 为空时，主 App 会自动把对应 bundle GIF 推到键盘上。"))

            HelpSection(title: String(localized: "text.1bdc77f51652", defaultValue: "替换成自己的 GIF"), body: String(localized: "text.4ea94b64c0bb", defaultValue: "1. 画布点 LCD 屏幕 → Inspector 显示「修改」\n2. 点「修改」进入编辑态（接管 BLE）\n3. 选择你的 .gif（推荐 ≤70 帧、≤2MB），可先在虚拟屏幕里预览\n4. 确认后点底部「写入键盘」统一写入设备"))

            HelpSection(title: String(localized: "text.3757b9236205", defaultValue: "LCD 角标的含义"), body: String(localized: "text.eeac94172870", defaultValue: "• 绿色「✓ 已上传 N 帧」：键盘 flash 真有 N 帧（你或自动同步推的）\n• 灰色「未上传」：键盘 flash 空，正显示固件默认或留空\n• 没有徽章：还没自占 BLE 查到（点过一次「修改」就有了）"))

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "text.c251e77b2274", defaultValue: "现在键盘 flash 各 Mode 状态")).font(.subheadline.weight(.medium))
                ForEach(AhaKeyModeSlot.allCases) { mode in
                    HStack {
                        Text(mode.title + " · " + mode.name).font(.callout)
                        Spacer()
                        if let s = bleManager.keyboardPictureStates[mode.rawValue] {
                            if s.frameCount > 0 {
                                Label(String(localized: "text.0cc0a6dc8d4e", defaultValue: "\(s.frameCount) 帧"), systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.callout)
                            } else {
                                Label(String(localized: "text.2f8267a89ad5", defaultValue: "空"), systemImage: "tray").foregroundStyle(.secondary).font(.callout)
                            }
                        } else {
                            Text(String(localized: "text.84d11bab76dc", defaultValue: "尚未查询")).font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            HelpNote("info.circle.fill", tint: .blue, body: String(localized: "text.6310d26dc60c", defaultValue: "切换 Mode 时 LCD 会先闪一下当前按键 description 文本（机械感效果），约 1 秒后回到该 Mode 的动图。"))
        }
    }
}

private struct LightBarTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "rainbow",
                title: String(localized: "text.3eaead948521", defaultValue: "灯条颜色"),
                subtitle: String(localized: "text.803253b86bf3", defaultValue: "8 颗 WS2812B，颜色由固件 update_claude_ws2812() 决定，1:1 还原在画布上")
            )

            HelpSection(title: String(localized: "text.35b6895ec63f", defaultValue: "颜色对照表"), body: String(localized: "text.02ae69ae7ca5", defaultValue: "下面是 Mode 1（Claude）下，固件按 IDE state 的实际行为："))

            VStack(alignment: .leading, spacing: 8) {
                HelpSwatch(
                    color: Color(red: 240/255, green: 32/255, blue: 41/255),
                    label: String(localized: "text.81012881d642", defaultValue: "0xF02029 (红)"),
                    detail: "SessionStart / Stop / PostToolUse / PermissionRequest / UserPromptSubmit"
                )
                HelpSwatch(
                    color: Color(red: 32/255, green: 80/255, blue: 255/255),
                    label: String(localized: "text.66516121b7bd", defaultValue: "0x2050FF (蓝)"),
                    detail: String(localized: "text.772c305ea788", defaultValue: "PreToolUse — 工具开始执行（manual 档专属）")
                )
                HelpSwatch(
                    color: Color.gray.opacity(0.3),
                    label: String(localized: "text.f2cbc28baae7", defaultValue: "OFF (熄灭)"),
                    detail: String(localized: "text.ec9d2621a8c9", defaultValue: "SessionEnd — Claude 会话结束")
                )
            }

            HelpSection(title: String(localized: "text.5aacb1a0409e", defaultValue: "Auto 档的彩虹覆盖"), body: String(localized: "text.f4f21d3d8251", defaultValue: "当拨杆 = auto (switchState=0) 时，固件把部分 state 强制改成彩虹效果：\n• PreToolUse / PermissionRequest → 整条彩虹波浪\n• PostToolUse / UserPromptSubmit → 单点彩虹流水\n这就是你看到「Cursor 一跑灯条变彩虹」的原因——是 auto 档的视觉提示，不是 Cursor 专属。"))

            HelpNote("exclamationmark.triangle.fill", tint: .orange, body: String(localized: "text.6b19394efdb4", defaultValue: "Mode 1 / Mode 2 时，固件的 update_claude_ws2812() 直接 return，**灯条不再随 IDE state 变**，会停在上一次设定的颜色上。这是固件设计，不是 bug。"))
        }
    }
}

private struct VoiceTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "mic.circle",
                title: String(localized: "text.2fdc91e671fd", defaultValue: "语音输入"),
                subtitle: String(localized: "text.2e21c593165b", defaultValue: "macOS 原生语音走 F18；Fn / Globe 触发走 F19")
            )

            HelpSection(title: String(localized: "text.b1ae606f1b55", defaultValue: "几种预设的差别"), body: String(localized: "text.eaf4d49e8193", defaultValue: "• macOS 原生转写：在地化语言识别，识别完 ⌘V 写回光标。适合任何输入框\n• Fn/Globe：用于 Typeless、微信语音、豆包输入法，在对应软件内把快捷键设为 Fn/Globe\n• 自定义快捷键：只写入键盘，不接管为固定语音预设\n• AhaType：先识别再优化提示词（需登录）"))

            HelpSection(title: String(localized: "text.dcd92eae2514", defaultValue: "短按 vs 长按"), body: String(localized: "text.f736a6bc4d66", defaultValue: "• 短按（Toggle）：第一次按开始，第二次按结束 — 适合长段话\n• 长按（Hold-to-speak）：按住时录音，松开停 — 适合微信、豆包等需要\"按住\"的输入法\n\n两种模式在 Key 1 Inspector 的「触发方式」Tab 里切换。"))

            HelpNote("hand.raised.fill", tint: .red, body: String(localized: "text.ce9e21020b26", defaultValue: "麦克风 + 输入监控 + 辅助功能三个权限都得给。打开「权限诊断」可以一键跳到系统设置对应页。"))
        }
    }
}

private struct DiagnosticsTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "stethoscope",
                title: String(localized: "text.22aa5b3f29c5", defaultValue: "权限诊断"),
                subtitle: String(localized: "text.db3cf27745fe", defaultValue: "点底栏的「权限诊断」按钮打开（不是这里的页面）")
            )

            HelpSection(title: String(localized: "text.58ff127f773c", defaultValue: "权限清单"), body: String(localized: "text.16aa35a929fa", defaultValue: "• 蓝牙：连接键盘必须\n• 麦克风：苹果原生转写、AhaType、按住说话所有语音功能都需要\n• 输入监控：捕获语音键的按下/松开事件\n• 辅助功能：模拟键盘按键（用于 ⌘V 写回文本、注入 Fn/Globe 等）\n• 语音识别：苹果原生转写\n• Siri 与听写（macOS 13+）：原生转写依赖项"))

            HelpSection(title: String(localized: "text.19d2e999dd9e", defaultValue: "Agent 健康检查"), body: String(localized: "text.74f2ce67ddc5", defaultValue: "打开「权限诊断」可以看到 Agent 自检结果：\n• LaunchAgent 已注册：login item 装好\n• 进程在跑：launchd 拉起了 ahakeyconfig-agent\n• Hook 已配置：Claude/Cursor/Codex/Kimi 的 .json / settings 都加好了 ahakey-hook 引用"))

            HelpSection(title: String(localized: "text.f9e119eba10a", defaultValue: "转写测试在哪"), body: String(localized: "text.a39faa338573", defaultValue: "权限诊断弹窗里。可以不连键盘就验证 macOS 原生转写是否能识别。如果转写失败，多半是麦克风权限或没装语言模型（系统设置 → Siri 与听写 → 听写语言）。"))
        }
    }
}

private struct FAQTopicView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpTitle(
                icon: "questionmark.bubble",
                title: String(localized: "text.45a6d115fdfb", defaultValue: "常见问题"),
                subtitle: String(localized: "text.1f7bb010c3a4", defaultValue: "如果下面没你的问题，可以提 issue 到 GitHub 仓库")
            )

            faq(
                q: String(localized: "text.a687fad058d8", defaultValue: "Hook 拦不住，AI 还是会停下来问我"),
                a: String(localized: "text.bed095af0a26", defaultValue: "按这顺序排查：\n1. Agent 在跑吗？打开「权限诊断」看\n2. Agent 是否占着蓝牙？画布顶部应显示已连接，且不在编辑态\n3. 拨杆在 auto 档？看顶部状态栏；不是的话点画布拨杆切到 auto\n4. IDE 的 Hook 文件配了吗？「权限诊断」会列出 Claude/Cursor/Codex/Kimi 各自的 Hook 安装状态\n5. 装完后是否重启过 IDE？尤其 Kimi 安装/升级后必须完全关闭再重开")
            )

            faq(
                q: String(localized: "text.86fa34c3188e", defaultValue: "画布上灯条不变色"),
                a: String(localized: "text.d68cf11393df", defaultValue: "• 检查右上角是否「已连接」\n• 切到正在用的 Mode\n• 触发一次工具调用让 Hook 真的发 0x90 给键盘\n• 如果是手动批准档 + Mode 1：preToolUse 是蓝、其他状态是红")
            )

            faq(
                q: String(localized: "text.6fc5fdf859f4", defaultValue: "LCD 自动同步没触发"),
                a: String(localized: "text.29fbaf44482f", defaultValue: "自动同步只在主 App 自占 BLE 时才查图片元信息。流程：\n1. 至少点一次「修改」让主 App 接管 BLE\n2. 四个 Mode 的 0x83 查询完成后才会触发\n3. 只对 flash 为空（picLength=0）的 Mode 生效\n4. 如果你曾经手动改过 Inspector 里的「上传 GIF」路径，自动同步会跳过那个 Mode（不覆盖你的选择）")
            )

            faq(
                q: String(localized: "text.024a3a544dee", defaultValue: "拨杆我点了，但键盘灯效没切"),
                a: String(localized: "text.451ada5d9d6b", defaultValue: "最新固件中 0x91 已用于灯效预览。虚拟拨杆只作为 Hook 软件覆盖，不再写入键盘 sw_state。")
            )

            faq(
                q: String(localized: "text.cf03746f25d2", defaultValue: "OTA 升级有吗？"),
                a: String(localized: "text.93190e90d3b0", defaultValue: "规划中，下一版本会做。当前所有固件升级都需要 USB-ISP（拆机短 BOOT + wchisp）。详细方案在仓库 docs 里。")
            )
        }
    }

    private func faq(q: String, a: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.tint)
                    .padding(.top, 1)
                Text(q).font(.callout.weight(.medium))
            }
            Text(a)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.leading, 26)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.leading, 26).padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
