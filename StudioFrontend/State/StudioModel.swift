import Combine
import Foundation

@MainActor
final class StudioModel: ObservableObject {
    let runtime = RuntimeStore()
    let drafts: StudioDraftStore
    let client: RuntimeClient
    let isMock: Bool
    @Published var selectedMode: AhaKeyModeSlot = .mode0
    @Published var selectedPart: AhaKeyStudioPart = .key1
    @Published private(set) var baseline: ConfigurationDocument?
    @Published private(set) var error: String?
    @Published private(set) var pending: [ApplyConfiguration]
    @Published private(set) var unknownOperationIDs: Set<String> = []
    private let defaults: UserDefaults
    private var observers = Set<AnyCancellable>()
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var stopped = true
    private var baselineGeneration = UUID()
    private let reconnectDelay: UInt64

    init(client: RuntimeClient, drafts: StudioDraftStore, defaults: UserDefaults, isMock: Bool, reconnectDelay: UInt64 = 2_000_000_000) {
        self.client = client
        self.drafts = drafts
        self.defaults = defaults
        self.isMock = isMock
        self.reconnectDelay = reconnectDelay
        pending = defaults.data(forKey: "studio.frontend.pending.v1")
            .flatMap { try? JSONDecoder().decode([ApplyConfiguration].self, from: $0) } ?? []
        runtime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        drafts.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        client.onEvent = { [weak self] event in self?.receive(event) }
        client.onDisconnect = { [weak self] error in
            guard let self, !self.stopped else { return }
            self.error = self.errorCode(error)
            self.baseline = nil
            self.runtime.markOffline()
            self.scheduleConnection()
        }
    }

    var device: RuntimeDevice? { runtime.devices.first }
    var currentDraft: AhaKeyModeDraft { drafts.draft.draft(for: selectedMode) }
    var validationError: String? {
        for mode in drafts.draft.modes {
            for key in mode.keys {
                if key.description.utf8.count > 20 || !key.description.unicodeScalars.allSatisfy({ $0.isASCII }) {
                    return "descriptionLimit"
                }
                if key.macro.count > 49 { return "macroLimit" }
            }
        }
        return nil
    }
    var hasConflict: Bool { device.map { runtime.invalidatedDevices.contains($0.id) } ?? false }
    var canApply: Bool {
        runtime.connection == .ready && device?.isReady == true && baseline?.configuration != nil
            && pending.isEmpty && !hasConflict && validationError == nil && runtime.methods.contains("configuration.apply")
    }

    func start() {
        guard stopped else { return }
        stopped = false
        scheduleConnection(immediate: true)
    }

    func reconnect() { scheduleConnection(immediate: true) }

    func stop() {
        stopped = true
        connectionGeneration = UUID()
        connectionTask?.cancel()
        client.disconnect()
        runtime.markOffline()
        baseline = nil
    }

    private func scheduleConnection(immediate: Bool = false) {
        guard !stopped else { return }
        let generation = UUID()
        connectionGeneration = generation
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                do { try await Task.sleep(nanoseconds: self.reconnectDelay) } catch { return }
            }
            guard generation == self.connectionGeneration else { return }
            self.runtime.beginConnection()
            self.baseline = nil
            do {
                let session = try await self.client.connect()
                guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                try self.runtime.install(session)
                self.error = nil
                await self.refreshBaseline()
                await self.recoverPending()
            } catch {
                guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                self.error = self.errorCode(error)
                self.runtime.markOffline()
                self.scheduleConnection()
            }
        }
    }

    func refreshBaseline() async {
        guard let device, runtime.connection == .ready, runtime.methods.contains("configuration.get") else { return }
        let generation = UUID()
        baselineGeneration = generation
        let epoch = runtime.configurationEpoch
        do {
            let document = try await client.configuration(deviceId: device.id)
            guard generation == baselineGeneration, runtime.connection == .ready,
                  document.deviceId == device.id, self.device?.id == device.id,
                  epoch == runtime.configurationEpoch else { return }
            baseline = document
            runtime.acknowledgeBaseline(for: device.id)
        } catch { self.error = errorCode(error) }
    }

    func save(allModes: Bool) async {
        guard canApply, let device, let baseline else { return }
        let modes = allModes ? AhaKeyModeSlot.allCases : [selectedMode]
        let request = ApplyConfiguration(
            operationId: UUID().uuidString, deviceId: device.id, baseToken: baseline.baseToken,
            scope: .init(deviceFields: ["brightnessPercent"], modes: modes.map(\.rawValue)),
            changes: drafts.configuration(modes: modes))
        // Persist before crossing the process boundary. A lost response is an unknown result.
        pending.append(request)
        persistPending()
        error = nil
        do {
            let accepted = try await client.apply(request)
            guard accepted.operationId == request.operationId else { throw RuntimeFailure.invalidMessage }
            // An event may have already completed the operation before this response.
            if !runtime.operations.contains(where: { $0.id == request.operationId }) {
                runtime.upsert(RuntimeOperation(operationId: request.operationId, deviceId: device.id, status: accepted.status))
            }
        } catch {
            self.error = errorCode(error)
            // Only explicit pre-acceptance rejection proves no operation was accepted.
            if case RuntimeFailure.remote(let code) = error,
               ["BASE_CONFLICT", "BUSY", "DEVICE_NOT_READY", "INVALID_PARAMS", "UNSUPPORTED_CAPABILITY", "INCOMPLETE_WRITE_GROUP"].contains(code) {
                pending.removeAll { $0.operationId == request.operationId }
                persistPending()
                self.baseline = nil
            } else if runtime.connection == .ready { await recoverPending() }
        }
    }

    func toggleDeviceConnection() async {
        guard let device else { return }
        do {
            if device.isReady { try await client.disconnectDevice(id: device.id) }
            else { try await client.connectDevice(id: device.id) }
        } catch { self.error = errorCode(error) }
    }

    func recoverPending() async {
        guard runtime.connection == .ready, runtime.methods.contains("operation.get") else { return }
        for request in pending {
            do {
                let operation = try await client.operation(id: request.operationId)
                guard operation.id == request.operationId, operation.deviceId == request.deviceId else { throw RuntimeFailure.invalidMessage }
                unknownOperationIDs.remove(request.operationId)
                runtime.upsert(operation)
                await finishIfNeeded(operation)
            } catch {
                self.error = errorCode(error)
                if case RuntimeFailure.remote("OPERATION_NOT_FOUND") = error {
                    unknownOperationIDs.insert(request.operationId)
                }
            }
        }
    }

    /// Explicitly acknowledged by the user after checking the device. Never resubmits a write.
    func acknowledgeUnknownResult() {
        pending.removeAll { unknownOperationIDs.contains($0.operationId) }
        unknownOperationIDs = []
        baseline = nil
        persistPending()
    }

    private func receive(_ event: RuntimeEvent) {
        do {
            try runtime.receive(event)
            guard runtime.connection == .ready else { return }
            // Consult the accepted projection, not the raw event (which may be stale).
            for operation in runtime.operations where operation.isTerminal && pending.contains(where: { $0.operationId == operation.id }) {
                Task { [weak self] in await self?.finishIfNeeded(operation) }
            }
        } catch {
            self.error = errorCode(error)
            client.disconnect()
            runtime.markOffline()
            scheduleConnection()
        }
    }

    private func finishIfNeeded(_ operation: RuntimeOperation) async {
        guard operation.isTerminal, pending.contains(where: { $0.operationId == operation.id }) else { return }
        pending.removeAll { $0.operationId == operation.id }
        unknownOperationIDs.remove(operation.id)
        persistPending()
        if operation.status == "completed" {
            await refreshBaseline()
        } else {
            baseline = nil
            error = operation.errorCode ?? "OPERATION_FAILED"
        }
    }

    private func persistPending() {
        do { defaults.set(try JSONEncoder().encode(pending), forKey: "studio.frontend.pending.v1") }
        catch { self.error = "PENDING_SAVE_FAILED" }
    }

    private func errorCode(_ error: Error) -> String {
        if case RuntimeFailure.remote(let code) = error { return code }
        if case RuntimeFailure.incompatibleProtocol = error { return "PROTOCOL_MISMATCH" }
        if case RuntimeFailure.invalidMessage = error { return "INVALID_MESSAGE" }
        if case RuntimeFailure.timeout = error { return "REQUEST_TIMEOUT" }
        return "RUNTIME_UNAVAILABLE"
    }
}
