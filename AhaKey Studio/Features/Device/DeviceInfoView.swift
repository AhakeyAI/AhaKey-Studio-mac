import SwiftUI

struct DeviceInfoView: View {
    @ObservedObject var bleManager: AhaKeyBLEManager
    @StateObject private var agentManager = AgentManager.shared
    @State private var isEditingName = false
    @State private var editableName = ""
    @State private var showAgentLog = false
    @State private var agentLogPanel = 0
    @State private var logPanelContentTick = 0
    @State private var showAgentRequiredForAgentBLE = false

    var body: some View {
        Form {
            // MARK: - 设备信息
            Section {
                HStack(spacing: 0) {
                    infoCell(String(localized: "text.1c69b1aa723a", defaultValue: "电量"), value: "\(bleManager.batteryLevel)%")
                    Divider()
                    infoCell(String(localized: "text.a981c51cd86a", defaultValue: "固件"), value: "v\(bleManager.firmwareMainVersion).\(bleManager.firmwareSubVersion)")
                    Divider()
                    infoCell(String(localized: "text.401b7f9ee169", defaultValue: "设备名"), value: bleManager.deviceName ?? "—")
                }
                .frame(height: 50)

                HStack(spacing: 0) {
                    infoCell(String(localized: "text.e4b76edd446f", defaultValue: "工作模式"), value: workModeName(bleManager.workMode))
                    Divider()
                    infoCell(String(localized: "text.3b579010a041", defaultValue: "灯光"), value: lightModeName(bleManager.lightMode))
                    Divider()
                    infoCell(String(localized: "text.f9ef695d7706", defaultValue: "信号"), value: "\(bleManager.signalStrength) dBm")
                }
                .frame(height: 50)
            } header: {
                Text(String(localized: "text.6c07bb6fd4b6", defaultValue: "设备信息"))
            }

            // MARK: - 蓝牙连接（App 与 Agent 二选一）
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "text.9a7a0997682e", defaultValue: "同一时间只能由本 App 或 Agent 其中之一连接键盘，请在此切换。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(BluetoothConnectionOwner.allCases) { owner in
                            let selected = agentManager.bluetoothConnectionOwner == owner
                            let disableAgent = owner == .agentDaemon && !agentManager.isInstalled
                            Button {
                                if owner == .agentDaemon && !agentManager.isInstalled {
                                    showAgentRequiredForAgentBLE = true
                                } else {
                                    agentManager.setBluetoothConnectionOwner(owner, bleManager: bleManager)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(owner.title)
                                        .fontWeight(selected ? .semibold : .regular)
                                    Text(owner == .ahaKeyStudio
                                         ? String(localized: "text.27a02a10d9e7", defaultValue: "改键、LCD、同步、本机灯效测试（macOS 暂不支持 USB 有线配置）")
                                         : String(localized: "text.3657219ad247", defaultValue: "Claude/Cursor/Codex/Kimi Hook、灯条状态、拨杆查询"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(disableAgent)
                        }
                    }
                    LabeledContent(String(localized: "text.cb62ebd689ee", defaultValue: "当前")) {
                        HStack(spacing: 6) {
                            Text(bleManager.isConnected ? String(localized: "text.071045dacafa", defaultValue: "本 App 已连接蓝牙") : String(localized: "text.b1e38d30259e", defaultValue: "本 App 未连接"))
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(agentBluetoothStatusText())
                        }
                        .font(.callout)
                    }
                }
            } header: {
                Text(String(localized: "text.b25a2ec2491f", defaultValue: "蓝牙连接"))
            }
            .alert(String(localized: "text.4a95dc511fd6", defaultValue: "需要先安装 Agent"), isPresented: $showAgentRequiredForAgentBLE) {
                Button(String(localized: "text.f867f3417859", defaultValue: "好"), role: .cancel) {}
            } message: {
                Text(String(localized: "text.99ba5aace416", defaultValue: "将蓝牙交给 `ahakeyconfig-agent` 前，请先在下方完成「安装并启用」，生成 LaunchAgent。"))
            }

            // MARK: - 拨杆状态
            Section {
                HStack {
                    Text(String(localized: "text.64a8ef2b4481", defaultValue: "拨杆档位"))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.switchState == 0 ? Color.green : Color.indigo)
                            .frame(width: 10, height: 10)
                            .animation(.easeInOut(duration: 0.1), value: bleManager.switchState)
                        Text(switchStateLabel(bleManager.switchState))
                    }
                }
            } header: {
                Text(String(localized: "text.64a8ef2b4481", defaultValue: "拨杆档位"))
            }

            // MARK: - LED 状态同步
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(agentManager.isRunning ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(String(localized: "text.a718375e06ce", defaultValue: "LED 跟随 IDE 状态"))
                            Text(agentBluetoothShortLabel())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            hookBadge("Claude", installed: agentManager.claudeHooksInstalled)
                            hookBadge("Cursor", installed: agentManager.cursorHooksInstalled)
                            hookBadge("Codex", installed: agentManager.codexHooksInstalled)
                            hookBadge("Kimi", installed: agentManager.kimiHooksInstalled)
                        }
                        .font(.caption)
                    }
                    Spacer()
                    if agentManager.isInstalled {
                        Button(agentManager.isRunning ? String(localized: "text.ca4d973c0b00", defaultValue: "停止") : String(localized: "text.56410fc65314", defaultValue: "启动")) {
                            if agentManager.isRunning {
                                agentManager.stop()
                            } else {
                                agentManager.start()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(agentManager.bluetoothConnectionOwner == .ahaKeyStudio)
                        .help(agentManager.bluetoothConnectionOwner == .ahaKeyStudio
                              ? String(localized: "text.4c8355db4128", defaultValue: "当前由本 App 占用蓝牙，Agent 应处于未加载。请先在「蓝牙连接」中选中 Agent 后再启停守护进程。")
                              : String(localized: "text.c02b3c774c0c", defaultValue: "从 launchd 加载并启动/卸载停止 Agent 进程。"))

                        Button(String(localized: "text.06bc14b60f35", defaultValue: "卸载"), role: .destructive) {
                            agentManager.uninstall(bleManager: bleManager)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            if agentManager.isAgentOperationInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button(String(localized: "text.a8ef0dcc54eb", defaultValue: "安装并启用")) {
                                agentManager.install()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(agentManager.isAgentOperationInProgress)
                        }
                    }
                }

                if agentManager.isInstalled {
                    HStack(spacing: 10) {
                        Button(String(localized: "text.659875587949", defaultValue: "查看日志")) {
                            showAgentLog.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Spacer()

                        if agentManager.claudeHooksInstalled {
                            Button(String(localized: "text.38c0194b92e5", defaultValue: "移除 Claude Hooks")) { agentManager.removeClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button(String(localized: "text.0be64d6dd419", defaultValue: "安装 Claude Hooks")) { agentManager.installClaudeHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.cursorHooksInstalled {
                            Button(String(localized: "text.3036929213da", defaultValue: "移除 Cursor Hooks")) { agentManager.removeCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button(String(localized: "text.220f6288a467", defaultValue: "安装 Cursor Hooks")) { agentManager.installCursorHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.codexHooksInstalled {
                            Button(String(localized: "text.e536977d952b", defaultValue: "移除 Codex Hooks")) { agentManager.removeCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button(String(localized: "text.e03ccb87eac3", defaultValue: "安装 Codex Hooks")) { agentManager.installCodexHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        if agentManager.kimiHooksInstalled {
                            Button(String(localized: "text.865c2ab9f878", defaultValue: "移除 Kimi Hooks")) { agentManager.removeKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        } else {
                            Button(String(localized: "text.f87630bdac69", defaultValue: "安装 Kimi Hooks")) { agentManager.installKimiHooksOnly() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            } header: {
                Text(String(localized: "text.3998f1402f57", defaultValue: "LED 状态同步 · Hook 联动"))
            } footer: {
                if !agentManager.isAgentBinaryPresentInBundle {
                    Text(String(localized: "text.7454a4058617", defaultValue: "发版包内未包含 ahakeyconfig-agent，无法使用守护进程。请用完整「AhaKey Studio.app」或联系开发者。"))
                        .foregroundStyle(.orange)
                } else if agentManager.isInstalled, agentManager.bluetoothConnectionOwner == .ahaKeyStudio, !agentManager.isRunning {
                    Text(String(localized: "text.7e7c6026b367", defaultValue: "已由本 App 占用蓝牙：要让 Agent 接管，请将「蓝牙连接」选为 ahakeyconfig-agent。"))
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showAgentLog) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "text.bb1d19b85634", defaultValue: "诊断日志"))
                            .font(.headline)
                        Spacer()
                        Button(String(localized: "text.3fd47edce45b", defaultValue: "关闭")) { showAgentLog = false }
                    }
                    Picker(String(localized: "text.7a688306423b", defaultValue: "内容"), selection: $agentLogPanel) {
                        Text(String(localized: "text.aad4719b1caf", defaultValue: "ahakeyconfig-agent 主日志")).tag(0)
                        Text(String(localized: "text.77ff03a2c75d", defaultValue: "工具批准（permission-request.log）")).tag(1)
                        Text("~/.cursor/hooks.json").tag(2)
                        Text("~/.cursor/cli-config.json").tag(3)
                        Text("~/.codex/config.toml").tag(4)
                        Text("Codex Hook（codex-hook.log）").tag(5)
                        Text("~/.kimi/config.toml").tag(6)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    HStack {
                        Button(String(localized: "text.449b30365898", defaultValue: "刷新本页")) {
                            logPanelContentTick += 1
                            agentManager.refresh()
                        }
                        if agentLogPanel == 3 {
                            Button(String(localized: "text.8abc47a83d03", defaultValue: "合并 CLI + IDE 终端白名单")) {
                                let a = agentManager.mergeUserCursorCliConfigForShellAutoApprove()
                                let b = agentManager.mergeUserCursorPermissionsJsonForAgentTUI()
                                agentManager.agentUserAlert = a + "\n\n——\n\n" + b
                            }
                            .help(String(localized: "text.13c0eea078d7", defaultValue: "写 cli-config（CLI）与 permissions.json 的 terminalAllowlist（Agent TUI「Not in allowlist」层）；分见官方文档。均先备份为 .ahakey.bak。"))
                        }
                        Spacer()
                    }
                    .font(.caption)
                    ScrollView {
                        logPanelContent
                            .id(logPanelContentTick)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(width: 540, height: 380)
            }

            // MARK: - LED 测试
            if bleManager.isConnected {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(Array(IDEState.allCases.enumerated()), id: \.offset) { _, state in
                            Button {
                                bleManager.updateIDEState(state)
                            } label: {
                                Text(state.label)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text(String(localized: "text.06528f8322f0", defaultValue: "LED 测试"))
                } footer: {
                    Text(String(localized: "text.27e7323e62a2", defaultValue: "点击按钮发送对应状态到键盘，观察 LED 变化。"))
                }
            }

            // MARK: - BLE 连接状态
            Section {
                LabeledContent(String(localized: "text.a5574109f020", defaultValue: "连接")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(bleManager.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(bleManager.bleConnectionStatus)
                    }
                }
                LabeledContent(String(localized: "text.401b7f9ee169", defaultValue: "设备名")) {
                    if isEditingName {
                        HStack(spacing: 4) {
                            TextField(String(localized: "text.012d599c2f22", defaultValue: "最长 15 字节"), text: $editableName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit { submitNameChange() }
                            Button(String(localized: "text.a3030bf8f16d", defaultValue: "保存")) { submitNameChange() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button(String(localized: "text.2cd0f3be8738", defaultValue: "取消")) { isEditingName = false }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(bleManager.deviceName ?? "—")
                                .textSelection(.enabled)
                            if bleManager.isConnected {
                                Button {
                                    editableName = bleManager.deviceName ?? ""
                                    isEditingName = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                LabeledContent("UUID") {
                    Text(bleManager.bleDeviceUUID)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    LabeledContent(String(localized: "text.2eb362148f03", defaultValue: "特征")) {
                        HStack(spacing: 8) {
                            charBadge("DATA", ready: bleManager.dataCharReady)
                            charBadge("CMD", ready: bleManager.commandCharReady)
                            charBadge("NOTIFY", ready: bleManager.notifyCharReady)
                        }
                    }
                }
            } header: {
                Text(String(localized: "text.9096705d515d", defaultValue: "BLE 连接状态"))
            }

            // MARK: - 操作
            Section {
                HStack {
                    if !bleManager.isConnected {
                        Button(bleManager.isScanning ? String(localized: "text.463fa583e0d3", defaultValue: "扫描中…") : String(localized: "text.7b4be6a35846", defaultValue: "连接设备")) {
                            bleManager.userInitiatedConnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(bleManager.isScanning || agentManager.bluetoothConnectionOwner == .agentDaemon)
                        .help(agentManager.bluetoothConnectionOwner == .agentDaemon
                              ? String(localized: "text.cb22b76447bd", defaultValue: "当前选择由 ahakeyconfig-agent 占用蓝牙。请先在上方「蓝牙连接」切到 AhaKey Studio，或点击顶栏「设备信息 · Agent」切换。")
                              : String(localized: "text.51a2114fc5c8", defaultValue: "本 App 主动连接键盘。"))
                    } else {
                        Button(String(localized: "text.8f0a33b3350f", defaultValue: "查询状态")) {
                            bleManager.queryDeviceStatus()
                        }
                        .buttonStyle(.bordered)
                        .help(String(localized: "text.93cc2e6c27ba", defaultValue: "发送 AA BB 00 CC DD 查询设备状态"))

                        Button(String(localized: "text.8a4f90c6004a", defaultValue: "探测协议")) {
                            bleManager.sendProbeCommands()
                        }
                        .buttonStyle(.bordered)
                        .help(String(localized: "text.3ea4770373fc", defaultValue: "向设备发送探测命令，观察通信日志中的回调"))

                        Spacer()

                        Button(String(localized: "text.f33ac04eece6", defaultValue: "断开"), role: .destructive) {
                            bleManager.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            // MARK: - 通信日志
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(bleManager.commLog) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.formattedTime)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 80, alignment: .leading)
                                        Text(entry.message)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(entry.isError ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                    .id(entry.id)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 150)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: bleManager.commLog.count) { _ in
                            if let last = bleManager.commLog.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button(String(localized: "text.75c393923f87", defaultValue: "复制全部")) {
                            let text = bleManager.commLog.map { "[\($0.formattedTime)] \($0.message)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button(String(localized: "text.1ef3de06b32e", defaultValue: "清空")) {
                            bleManager.clearLog()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text(String(localized: "text.8d2281865e4c", defaultValue: "通信日志"))
            }
        }
        // 「设备信息」在 sheet 中展示时，父视图的 `.alert` 往往不会置顶显示，导致 Hooks 安装/报错像「无反应」。在此重复绑定以确保可见。
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

    }

    // MARK: - Components

    private func infoCell(_ label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func hookBadge(_ label: String, installed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
            Text(String(localized: "device.hooks.title", defaultValue: "\(label) Hooks"))
                .foregroundStyle(installed ? .primary : .secondary)
        }
    }

    private func charBadge(_ label: String, ready: Bool) -> some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ready ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .foregroundStyle(ready ? Color.green : Color.secondary)
    }

    private func switchStateLabel(_ state: Int) -> String {
        state == 0 ? String(localized: "text.33a4c1e02545", defaultValue: "自动批准") : String(localized: "text.4f87c2cea203", defaultValue: "手动批准")
    }

    private func agentBluetoothStatusText() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return String(localized: "text.78e3b7a3c292", defaultValue: "Agent 已连接蓝牙") }
        if agentManager.isRunning { return String(localized: "text.a5ea296347a0", defaultValue: "Agent 运行中（BLE 未连接）") }
        if agentManager.isInstalled { return String(localized: "text.bd847d5f0d2b", defaultValue: "Agent 未运行") }
        return String(localized: "text.b03902d4343e", defaultValue: "Agent 未安装")
    }

    private func agentBluetoothShortLabel() -> String {
        if agentManager.isRunning && agentManager.isAgentBLEConnected { return String(localized: "text.e44a6ab75925", defaultValue: "已连蓝牙") }
        if agentManager.isRunning { return String(localized: "text.e1f3636309ef", defaultValue: "BLE 未连接") }
        if agentManager.isInstalled { return String(localized: "text.62cdc8713bcf", defaultValue: "未运行") }
        return String(localized: "text.e1a58c659b33", defaultValue: "未装 Agent")
    }

    private func workModeName(_ mode: Int) -> String {
        guard let slot = AhaKeyModeSlot(rawValue: mode) else {
            return String(localized: "device.mode.unknown", defaultValue: "未知模式（\(mode)）")
        }
        return String(localized: "device.mode.summary", defaultValue: "\(slot.title) / \(slot.defaultName)")
    }

    private func lightModeName(_ mode: Int) -> String {
        switch mode {
        case 0: return String(localized: "device.lighting.off", defaultValue: "关闭")
        case 1: return String(localized: "text.a508dadda912", defaultValue: "常亮")
        case 2: return String(localized: "text.280e12a8d2af", defaultValue: "呼吸")
        default: return "\(mode)"
        }
    }

    @ViewBuilder
    private var logPanelContent: some View {
        switch agentLogPanel {
        case 0:
            Text(agentManager.readLog())
        case 1:
            Text(agentManager.readPermissionRequestLog())
        case 2:
            Text(agentManager.readUserCursorHooksJsonForDisplay())
        case 3:
            Text(agentManager.readUserCursorCliConfigForDisplay())
        case 4:
            Text(agentManager.readUserCodexConfigForDisplay())
        case 5:
            Text(agentManager.readCodexHookLog())
        case 6:
            Text(agentManager.readUserKimiConfigForDisplay())
        default:
            Text("")
        }
    }

    private func submitNameChange() {
        let name = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        bleManager.changeDeviceName(name)
        isEditingName = false
    }
}
