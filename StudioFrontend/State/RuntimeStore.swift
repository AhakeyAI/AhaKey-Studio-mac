import Combine
import Foundation

@MainActor
final class RuntimeStore: ObservableObject {
    enum Connection: Equatable { case offline, connecting, ready }
    @Published private(set) var connection: Connection = .offline
    @Published private(set) var devices: [RuntimeDevice] = []
    @Published private(set) var operations: [RuntimeOperation] = []
    @Published private(set) var methods: Set<String> = []
    @Published private(set) var invalidatedDevices: Set<String> = []
    private var instanceId: String?
    private var subscriptionId: String?
    private var sequence: UInt64 = 0
    private var buffered: [RuntimeEvent] = []
    private(set) var configurationEpoch: UInt64 = 0

    func beginConnection() {
        configurationEpoch &+= 1
        connection = .connecting
        methods = []
        buffered = []
        subscriptionId = nil
    }

    func install(_ session: RuntimeSession) throws {
        let snapshot = session.subscription.snapshot
        guard snapshot.instanceId == session.hello.instanceId,
              let sequence = UInt64(snapshot.sequence) else { throw RuntimeFailure.invalidMessage }
        instanceId = snapshot.instanceId
        subscriptionId = session.subscription.subscriptionId
        self.sequence = sequence
        devices = snapshot.devices
        operations = snapshot.operations
        methods = Set(session.hello.methods)
        invalidatedDevices = []
        connection = .ready
        let events = buffered
        buffered = []
        for event in events { try receive(event) }
    }

    func receive(_ event: RuntimeEvent) throws {
        if connection == .connecting {
            guard buffered.count < 256 else { throw RuntimeFailure.invalidMessage }
            buffered.append(event)
            return
        }
        guard connection == .ready, event.instanceId == instanceId, event.subscriptionId == subscriptionId else { return }
        guard let next = UInt64(event.sequence) else { throw RuntimeFailure.invalidMessage }
        guard next > sequence else { return }
        // Filtered topics can skip global sequence numbers; only monotonicity is required.
        switch event.type {
        case "device.changed":
            let device = try event.data.decoded(RuntimeDevice.self)
            devices.removeAll { $0.id == device.id }
            devices.append(device)
        case "operation.changed": upsert(try event.data.decoded(RuntimeOperation.self))
        case "configuration.changed", "configuration.invalidated":
            configurationEpoch &+= 1
            if let id = event.data["deviceId"]?.string { invalidatedDevices.insert(id) }
        default: break
        }
        sequence = next
    }

    func upsert(_ operation: RuntimeOperation) {
        operations.removeAll { $0.id == operation.id }
        operations.append(operation)
    }

    func acknowledgeBaseline(for id: String) { invalidatedDevices.remove(id) }

    func markOffline() {
        configurationEpoch &+= 1
        connection = .offline
        methods = []
        devices = [] // Do not display a stale connected device after transport loss.
        subscriptionId = nil
        buffered = []
    }
}
