import Foundation

/// Explicit development backend. Never used as a fallback for a failed real connection.
@MainActor
final class MockRuntimeClient: RuntimeClient {
    var onEvent: ((RuntimeEvent) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var failNextApply = false
    var loseNextAcceptedResponse = false
    private let instanceId = UUID().uuidString
    private var subscriptionId: String?
    private var sequence: UInt64 = 0
    private var revision = 1
    private var device = RuntimeDevice(deviceId: "mock-x1", name: "AhaKey X1 · Mock", connectionState: "ready", batteryPercent: 82, workMode: 0, lever: "manual")
    private var stored: DeviceConfiguration
    private var requests: [String: ApplyConfiguration] = [:]
    private var operations: [String: RuntimeOperation] = [:]
    private let stepDelay: UInt64

    init(configuration: DeviceConfiguration, stepDelay: UInt64 = 350_000_000) {
        stored = configuration
        self.stepDelay = stepDelay
    }

    func connect() async throws -> RuntimeSession {
        subscriptionId = UUID().uuidString
        return RuntimeSession(
            hello: RuntimeHello(protocol: .init(major: 1, minor: 0), instanceId: instanceId, runtimeVersion: "mock", methods: [
                "runtime.subscribe", "configuration.get", "configuration.apply", "operation.get", "device.connect", "device.disconnect",
            ]),
            subscription: RuntimeSubscription(subscriptionId: subscriptionId!, snapshot: RuntimeSnapshot(
                instanceId: instanceId, sequence: String(sequence), devices: [device], operations: Array(operations.values))))
    }

    func disconnect() { subscriptionId = nil }

    func configuration(deviceId: String) async throws -> ConfigurationDocument {
        try requireDevice(deviceId)
        return ConfigurationDocument(deviceId: deviceId, baseToken: String(revision), configuration: stored)
    }

    func apply(_ request: ApplyConfiguration) async throws -> OperationAccepted {
        try requireDevice(request.deviceId)
        if let previous = requests[request.operationId] {
            guard previous == request else { throw RuntimeFailure.remote("OPERATION_ID_CONFLICT") }
            return OperationAccepted(operationId: request.operationId, status: operations[request.operationId]!.status)
        }
        guard device.isReady else { throw RuntimeFailure.remote("DEVICE_NOT_READY") }
        guard !operations.values.contains(where: { !$0.isTerminal }) else { throw RuntimeFailure.remote("BUSY") }
        guard request.baseToken == String(revision) else { throw RuntimeFailure.remote("BASE_CONFLICT") }
        requests[request.operationId] = request
        let shouldFail = failNextApply
        failNextApply = false
        let loseResponse = loseNextAcceptedResponse
        loseNextAcceptedResponse = false
        var operation = RuntimeOperation(operationId: request.operationId, deviceId: device.deviceId, status: "accepted", progress: 0, effect: "none")
        operations[operation.id] = operation
        emit("operation.changed", operation)
        Task { [self] in
            for step in 1...4 {
                try? await Task.sleep(nanoseconds: stepDelay)
                operation.status = "running"
                operation.progress = Double(step) / 4
                operations[operation.id] = operation
                emit("operation.changed", operation)
            }
            if shouldFail {
                if let mode = request.changes.modes.first,
                   let index = stored.modes.firstIndex(where: { $0.mode == mode.mode }),
                   let key = mode.keys.first {
                    stored.modes[index].keys.removeAll { $0.role == key.role }
                    stored.modes[index].keys.append(key)
                }
                revision += 1
                operation.status = "failed"
                operation.errorCode = "DEVICE_TIMEOUT"
                operation.effect = "partial"
            } else {
                for mode in request.changes.modes {
                    stored.modes.removeAll { $0.mode == mode.mode }
                    stored.modes.append(mode)
                }
                if request.scope.deviceFields.contains("brightnessPercent") { stored.device = request.changes.device }
                revision += 1
                operation.status = "completed"
                operation.effect = "complete"
            }
            operations[operation.id] = operation
            emit("operation.changed", operation)
            emit("configuration.changed", ["deviceId": device.deviceId, "baseToken": String(revision)])
        }
        if loseResponse {
            simulateConnectionLoss()
            throw RuntimeFailure.disconnected
        }
        return OperationAccepted(operationId: operation.id, status: "accepted")
    }

    func operation(id: String) async throws -> RuntimeOperation {
        guard subscriptionId != nil else { throw RuntimeFailure.disconnected }
        guard let operation = operations[id] else { throw RuntimeFailure.remote("OPERATION_NOT_FOUND") }
        return operation
    }

    func connectDevice(id: String) async throws {
        try requireDevice(id)
        device.connectionState = "ready"
        emit("device.changed", device)
    }

    func disconnectDevice(id: String) async throws {
        try requireDevice(id)
        guard !operations.values.contains(where: { !$0.isTerminal }) else { throw RuntimeFailure.remote("BUSY") }
        device.connectionState = "disconnected"
        emit("device.changed", device)
    }

    func simulateExternalChange() {
        revision += 1
        stored.device.brightnessPercent = stored.device.brightnessPercent == 65 ? 35 : 65
        emit("configuration.changed", ["deviceId": device.deviceId, "baseToken": String(revision)])
    }

    func simulateConnectionLoss() {
        disconnect()
        onDisconnect?(RuntimeFailure.disconnected)
    }

    private func requireDevice(_ id: String) throws {
        guard subscriptionId != nil else { throw RuntimeFailure.disconnected }
        guard id == device.deviceId else { throw RuntimeFailure.remote("DEVICE_NOT_FOUND") }
    }

    private func emit<T: Encodable>(_ type: String, _ data: T) {
        sequence += 1
        guard let subscriptionId, let value = try? RPCValue.encoded(data) else { return }
        onEvent?(RuntimeEvent(subscriptionId: subscriptionId, instanceId: instanceId, sequence: String(sequence), type: type, data: value))
    }
}
