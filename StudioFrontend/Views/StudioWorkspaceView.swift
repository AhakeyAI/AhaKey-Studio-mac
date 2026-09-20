import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioWorkspaceView: View {
    @ObservedObject var model: StudioModel
    @State private var previewState: IDEState = .preToolUse
    @State private var showsAccount = false
    @State private var showsOLED = false
    @State private var showsUnknownConfirmation = false
    @State private var showsRebaseConfirmation = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.isMock {
                banner(frontendText("mockNotice"), color: .orange)
            } else if model.runtime.connection != .ready {
                banner(frontendText("offlineNotice"), color: .secondary)
            }
            if model.runtime.connection == .ready && model.baseline?.configuration == nil && model.pending.isEmpty {
                banner(frontendText("unknownBaseline"), color: .secondary)
            }
            HSplitView {
                VStack(spacing: 16) {
                    Picker(frontendText("editingMode"), selection: $model.selectedMode) {
                        ForEach(AhaKeyModeSlot.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    AhaKeyKeyboardCanvasView(
                        modeDraft: model.currentDraft,
                        selectedPart: model.selectedPart,
                        lightBarPreview: previewState,
                        switchTitle: leverTitle,
                        isAutomaticApproval: model.device?.isReady == true && model.device?.lever == "automatic",
                        dirtyParts: dirtyParts,
                        onSelect: { model.selectedPart = $0 },
                        onModeSwitch: { model.selectedMode = AhaKeyModeSlot(rawValue: (model.selectedMode.rawValue + 1) % 4)! },
                        switchState: model.device?.isReady == true && model.device?.lever == "automatic" ? 0 : 1
                    )
                    .frame(minHeight: 330)
                    Text(frontendText("canvasNotice"))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.device?.isReady == true, let mode = model.device?.workMode {
                        Text("\(frontendText("deviceMode")): \(mode)").font(.caption)
                    }
                    operationPanel
                }
                .padding(24)
                .frame(minWidth: 630, maxWidth: .infinity, maxHeight: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(model.selectedPart.title).font(.title2.weight(.semibold))
                        inspector
                    }.padding(24)
                }
                .frame(minWidth: 350, idealWidth: 390, maxWidth: 470)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1100, minHeight: 720)
        .sheet(isPresented: $showsAccount) { CloudAccountView() }
        .sheet(isPresented: $showsOLED) {
            OLEDMotionPreviewSheet(modeTitle: model.selectedMode.title, assetPath: model.currentDraft.oled.localAssetPath, fps: model.currentDraft.oled.framesPerSecond)
        }
        .alert(frontendText("unknownTitle"), isPresented: $showsUnknownConfirmation) {
            Button(frontendText("checkedDevice"), role: .destructive) { model.acknowledgeUnknownResult() }
            Button(frontendText("cancel"), role: .cancel) {}
        } message: { Text(frontendText("unknownBody")) }
        .alert(frontendText("rebaseTitle"), isPresented: $showsRebaseConfirmation) {
            Button(frontendText("keepDraft")) { Task { await model.refreshBaseline() } }
            Button(frontendText("cancel"), role: .cancel) {}
        } message: { Text(frontendText("rebaseBody")) }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Image(systemName: "keyboard").font(.title2)
            Text("AhaKey Studio").font(.headline)
            if model.isMock { Text("MOCK").font(.caption.bold()).foregroundStyle(.orange) }
            Spacer()
            Text(model.device?.name ?? frontendText("noDevice"))
            Text(model.device?.isReady == true ? (model.device?.batteryPercent.map { "\($0)%" } ?? "—") : "—")
                .monospacedDigit()
            Button(frontendText("reconnect")) { model.reconnect() }
            if let device = model.device {
                Button(frontendText(device.isReady ? "disconnectDevice" : "connectDevice")) {
                    Task { await model.toggleDeviceConnection() }
                }
                .disabled(!model.pending.isEmpty || !model.runtime.methods.contains(device.isReady ? "device.disconnect" : "device.connect"))
            }
            Button(frontendText("account")) { showsAccount = true }
            if let mock = model.client as? MockRuntimeClient {
                Menu(frontendText("scenarios")) {
                    Button(frontendText("externalChange")) { mock.simulateExternalChange() }
                    Button(frontendText("failNext")) { mock.failNextApply = true }
                    Button(frontendText("loseResponse")) { mock.loseNextAcceptedResponse = true }
                    Button(frontendText("loseConnection")) { mock.simulateConnectionLoss() }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var inspector: some View {
        if let role = model.selectedPart.keyRole {
            keyEditor(role)
        } else if model.selectedPart == .lightBar {
            lightEditor
        } else if model.selectedPart == .oledDisplay {
            oledEditor
        } else {
            Text(leverTitle).font(.headline)
            Text(frontendText("leverNotice")).foregroundStyle(.secondary)
            Text(frontendText("servicesNotice")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func keyEditor(_ role: AhaKeyKeyRole) -> some View {
        let key = model.currentDraft.key(for: role)
        return VStack(alignment: .leading, spacing: 16) {
            TextField(frontendText("description"), text: keyBinding(role, \.description))
            Picker(frontendText("action"), selection: Binding(
                get: { key.usesMacro ? "macro" : "shortcut" },
                set: { value in
                    model.drafts.updateMode(model.selectedMode) { mode in
                        var key = mode.key(for: role)
                        key.macro = value == "macro" ? [.init(action: .noOp)] : []
                        key.voicePreset = nil
                        mode.updateKey(key)
                    }
                })) {
                Text(frontendText("shortcut")).tag("shortcut")
                Text(frontendText("macro")).tag("macro")
            }.pickerStyle(.segmented)
            if key.usesMacro {
                ForEach(key.macro) { step in
                    HStack {
                        Picker("", selection: macroBinding(role, step, \.action)) {
                            ForEach(MacroAction.allCases) { Text($0.title).tag($0) }
                        }
                        if step.action.takesDelayParam {
                            Stepper(value: Binding(
                                get: { Int(macroBinding(role, step, \.param).wrappedValue) * 3 },
                                set: { macroBinding(role, step, \.param).wrappedValue = UInt8(clamping: $0 / 3) }), in: 0...765, step: 3) {
                                Text("\(Int(step.param) * 3) ms").monospacedDigit()
                            }
                        } else if step.action.takesKeycodeParam {
                            Picker("", selection: macroBinding(role, step, \.param)) {
                                ForEach(HIDUsage.allOptions, id: \.code) { Text($0.name).tag($0.code) }
                            }
                        }
                        Button {
                            model.drafts.updateMode(model.selectedMode) { mode in
                                var key = mode.key(for: role)
                                key.macro.removeAll { $0.id == step.id }
                                mode.updateKey(key)
                            }
                        } label: { Image(systemName: "minus.circle") }
                    }
                }
                Button(frontendText("addStep")) {
                    model.drafts.updateMode(model.selectedMode) { mode in
                        var key = mode.key(for: role)
                        key.macro.append(.init(action: .downKey, param: HIDUsage.enter))
                        mode.updateKey(key)
                    }
                }.disabled(key.macro.count >= 49)
            } else {
                ShortcutBindingEditor(shortcut: keyBinding(role, \.shortcut))
            }
            Button(frontendText("disableKey")) {
                model.drafts.updateMode(model.selectedMode) { mode in
                    var key = mode.key(for: role)
                    key.shortcut = ShortcutBinding()
                    key.macro = []
                    key.voicePreset = nil
                    mode.updateKey(key)
                }
            }
            if role == .voice {
                Text(frontendText("voiceNotice")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lightEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(frontendText("globalBrightness")).font(.headline)
            Slider(value: Binding(get: { Double(model.drafts.brightness) }, set: { model.drafts.brightness = Int($0) }), in: 1...100, step: 1)
            Text("\(model.drafts.brightness)%").monospacedDigit()
            Picker(frontendText("previewState"), selection: $previewState) {
                ForEach(IDEState.workflowOrder) { Text($0.shortLabel).tag($0) }
            }
            ForEach(IDEState.workflowOrder) { state in
                Picker(state.shortLabel, selection: Binding(
                    get: { model.currentDraft.lightBar.effect(for: state) },
                    set: { effect in
                        model.drafts.updateMode(model.selectedMode) { mode in
                            mode.lightBar.stateMappings.removeAll { $0.state == state }
                            mode.lightBar.stateMappings.append(.init(state: state, effect: effect))
                        }
                    })) {
                    ForEach(LightEffectStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            Text(frontendText("localPreview")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var oledEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let path = model.currentDraft.oled.localAssetPath {
                AnimatedGIFView(path: path, fps: model.currentDraft.oled.framesPerSecond).frame(height: 150)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption)
            }
            Button(frontendText("chooseGIF")) { chooseGIF() }
            Button(frontendText("preview")) { showsOLED = true }
                .disabled(model.currentDraft.oled.localAssetPath == nil)
            Stepper(value: Binding(
                get: { model.currentDraft.oled.framesPerSecond },
                set: { fps in model.drafts.updateMode(model.selectedMode) { $0.oled.framesPerSecond = fps } }), in: 1...30) {
                    Text("\(model.currentDraft.oled.framesPerSecond) FPS")
                }
            Text(frontendText("oledNotice")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var operationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let operation = model.runtime.operations.last {
                HStack {
                    Text(frontendText(model.isMock ? "mockOperation" : "operation"))
                    Text(frontendText("status." + operation.status)).font(.caption)
                    if let effect = operation.effect, effect == "partial" || effect == "unknown" {
                        Text(frontendText("effect." + effect)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !operation.isTerminal { ProgressView(value: operation.progress ?? 0) }
            }
            if !model.pending.isEmpty {
                Text(frontendText("pendingNotice")).font(.caption)
                Button(frontendText("checkResult")) { Task { await model.recoverPending() } }
            }
            if !model.unknownOperationIDs.isEmpty {
                Button(frontendText("unknownTitle")) { showsUnknownConfirmation = true }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(frontendText(model.hasConflict ? "conflictNotice" : "draftNotice"))
                if let error = localError ?? model.error ?? model.drafts.persistenceError {
                    Text(frontendText(error)).font(.caption).foregroundStyle(.red)
                }
                if let issue = model.validationError {
                    Text(frontendText(issue)).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button(frontendText("refreshBaseline")) { showsRebaseConfirmation = true }
                .disabled(model.runtime.connection != .ready || !model.pending.isEmpty)
            Button(frontendText("saveMode")) { Task { await model.save(allModes: false) } }.disabled(!model.canApply)
            Button(frontendText("saveAll")) { Task { await model.save(allModes: true) } }
                .buttonStyle(.borderedProminent).disabled(!model.canApply)
        }.padding(16).fixedSize(horizontal: false, vertical: true)
    }

    private var leverTitle: String {
        guard model.device?.isReady == true else { return frontendText("unknown") }
        return frontendText(model.device?.lever == "automatic" ? "automatic" : model.device?.lever == "manual" ? "manual" : "unknown")
    }

    private var dirtyParts: Set<AhaKeyStudioPart> {
        guard let previous = model.baseline?.configuration?.modes.first(where: { $0.mode == model.selectedMode.rawValue }),
              let current = model.drafts.configuration(modes: [model.selectedMode]).modes.first else { return [] }
        var parts = Set<AhaKeyStudioPart>()
        for role in AhaKeyKeyRole.allCases {
            let name = ["voice", "approve", "reject", "submit"][role.rawValue]
            if previous.keys.first(where: { $0.role == name }) != current.keys.first(where: { $0.role == name }) { parts.insert(role.part) }
        }
        if previous.lights != current.lights || model.drafts.brightness != model.baseline?.configuration?.device.brightnessPercent { parts.insert(.lightBar) }
        return parts
    }

    private func keyBinding<T>(_ role: AhaKeyKeyRole, _ path: WritableKeyPath<AhaKeyKeyDraft, T>) -> Binding<T> {
        Binding(get: { model.currentDraft.key(for: role)[keyPath: path] }, set: { value in
            model.drafts.updateMode(model.selectedMode) { mode in
                var key = mode.key(for: role)
                key[keyPath: path] = value
                key.voicePreset = nil
                mode.updateKey(key)
            }
        })
    }

    private func macroBinding<T>(_ role: AhaKeyKeyRole, _ step: MacroStep, _ path: WritableKeyPath<MacroStep, T>) -> Binding<T> {
        Binding(get: { (model.currentDraft.key(for: role).macro.first { $0.id == step.id } ?? step)[keyPath: path] }, set: { value in
            model.drafts.updateMode(model.selectedMode) { mode in
                var key = mode.key(for: role)
                guard let index = key.macro.firstIndex(where: { $0.id == step.id }) else { return }
                key.macro[index][keyPath: path] = value
                mode.updateKey(key)
            }
        })
    }

    private func chooseGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 2 * 1024 * 1024 else { throw RuntimeFailure.remote("GIF_TOO_LARGE") }
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("AhaKey/StudioFrontend/Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(UUID().uuidString + ".gif")
            try FileManager.default.copyItem(at: url, to: copy)
            model.drafts.updateMode(model.selectedMode) { $0.oled.localAssetPath = copy.path }
            localError = nil
        } catch { localError = "GIF_IMPORT_FAILED" }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 9)
            .background(color.opacity(0.08))
    }
}
