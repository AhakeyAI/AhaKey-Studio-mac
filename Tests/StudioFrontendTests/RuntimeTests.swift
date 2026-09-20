import XCTest
@testable import StudioFrontend

@MainActor
final class RuntimeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "ai.ahakey.frontend.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate())
    }

    private func setupModel(stepDelay: UInt64 = 10_000_000) -> (StudioModel, MockRuntimeClient) {
        let defaults = defaults()
        let drafts = StudioDraftStore(defaults: defaults)
        let mock = MockRuntimeClient(configuration: drafts.configuration(modes: AhaKeyModeSlot.allCases), stepDelay: stepDelay)
        let model = StudioModel(client: mock, drafts: drafts, defaults: defaults, isMock: true, reconnectDelay: 10_000_000)
        addTeardownBlock { await MainActor.run { model.stop() } }
        return (model, mock)
    }

    func testWireConfigurationDoesNotExportPathsOrFirmwareEncoding() throws {
        let drafts = StudioDraftStore(defaults: defaults())
        drafts.updateMode(.mode0) { $0.oled.localAssetPath = "/private/user/secret.gif" }
        drafts.brightness = 67
        let wire = drafts.configuration(modes: [.mode0])
        let json = try RPCValue.encoded(wire)
        let string = String(data: try JSONEncoder().encode(wire), encoding: .utf8)!
        XCTAssertFalse(string.contains("secret"))
        XCTAssertFalse(string.contains("statusLine"))
        XCTAssertFalse(string.contains("firmwareIndex"))
        XCTAssertEqual(json["device"]?["brightnessPercent"], .number(67))
        let reject = try XCTUnwrap(wire.modes.first?.keys.first { $0.role == "reject" })
        guard case .macro(let steps) = reject.action else { return XCTFail("Expected semantic macro") }
        XCTAssertEqual(steps.filter { $0.type == "delay" }.map(\.delayMs), [15, 15])
        XCTAssertEqual(try JSONDecoder().decode(DeviceConfiguration.self, from: JSONEncoder().encode(wire)), wire)
    }

    func testShortcutAndDisabledActionsUseTaggedWireShape() throws {
        let action = KeyAction.shortcut(modifiers: ["gui"], keyCode: 40)
        let encoded = try RPCValue.encoded(action)
        XCTAssertEqual(encoded["type"], .string("shortcut"))
        XCTAssertEqual(encoded["modifiers"], .array([.string("gui")]))
        XCTAssertEqual(try RPCValue.encoded(KeyAction.disabled), .object(["type": .string("disabled")]))
    }

    func testDraftPersistsSeparatelyFromBackendState() {
        let preferences = defaults()
        let draft = StudioDraftStore(defaults: preferences)
        draft.brightness = 73
        draft.updateMode(.mode1) { mode in
            var key = mode.key(for: .approve)
            key.description = "Edited"
            mode.updateKey(key)
        }
        let restored = StudioDraftStore(defaults: preferences)
        XCTAssertEqual(restored.brightness, 73)
        XCTAssertEqual(restored.draft.draft(for: .mode1).key(for: .approve).description, "Edited")
    }

    func testSubscriptionBuffersEarlyEventsAndRejectsStaleSubscriptions() throws {
        let store = RuntimeStore()
        let device = RuntimeDevice(deviceId: "x1", name: "Keyboard", connectionState: "ready", batteryPercent: nil)
        let initial = RuntimeSnapshot(instanceId: "boot", sequence: "9007199254740993", devices: [], operations: [])
        store.beginConnection()
        try store.receive(.init(subscriptionId: "new", instanceId: "boot", sequence: "9007199254740995", type: "device.changed", data: .encoded(device)))
        try store.install(.init(hello: .init(protocol: .init(major: 1, minor: 0), instanceId: "boot", runtimeVersion: "test", methods: []), subscription: .init(subscriptionId: "new", snapshot: initial)))
        XCTAssertEqual(store.devices.first, device)
        var stale = device
        stale.name = "Stale"
        try store.receive(.init(subscriptionId: "old", instanceId: "boot", sequence: "9007199254741000", type: "device.changed", data: .encoded(stale)))
        try store.receive(.init(subscriptionId: "new", instanceId: "boot", sequence: "9007199254740994", type: "device.changed", data: .encoded(stale)))
        XCTAssertEqual(store.devices.first?.name, "Keyboard")
        store.markOffline()
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testEditsDuringApplyAreNotMarkedAsSaved() async throws {
        let (model, _) = setupModel()
        model.start()
        try await waitUntil { model.canApply }
        model.drafts.brightness = 61
        await model.save(allModes: false)
        model.drafts.brightness = 79
        try await waitUntil { model.pending.isEmpty && model.baseline?.configuration?.device.brightnessPercent == 61 }
        XCTAssertEqual(model.drafts.brightness, 79)
        XCTAssertEqual(model.runtime.operations.last?.status, "completed")
    }

    func testLostAcceptanceResponseRecoversOriginalOperationWithoutResubmitting() async throws {
        let (model, mock) = setupModel(stepDelay: 30_000_000)
        model.start()
        try await waitUntil { model.canApply }
        mock.loseNextAcceptedResponse = true
        await model.save(allModes: true)
        let id = try XCTUnwrap(model.pending.first?.operationId)
        try await waitUntil { model.runtime.connection == .ready && model.pending.isEmpty }
        XCTAssertEqual(model.runtime.operations.count, 1)
        XCTAssertEqual(model.runtime.operations.first?.id, id)
        XCTAssertEqual(model.runtime.operations.first?.status, "completed")
    }

    func testExternalChangeBlocksSaveAndKeepsDraft() async throws {
        let (model, mock) = setupModel()
        model.start()
        try await waitUntil { model.canApply }
        model.drafts.brightness = 88
        mock.simulateExternalChange()
        XCTAssertTrue(model.hasConflict)
        XCTAssertFalse(model.canApply)
        await model.save(allModes: false)
        XCTAssertTrue(model.pending.isEmpty)
        await model.refreshBaseline()
        XCTAssertEqual(model.drafts.brightness, 88)
        XCTAssertEqual(model.baseline?.configuration?.device.brightnessPercent, 65)
        XCTAssertTrue(model.canApply)
    }

    func testPartialFailureIsNotSuccessOrAutomaticRetry() async throws {
        let (model, mock) = setupModel()
        model.start()
        try await waitUntil { model.canApply }
        mock.failNextApply = true
        await model.save(allModes: false)
        try await waitUntil { model.pending.isEmpty }
        XCTAssertEqual(model.runtime.operations.last?.status, "failed")
        XCTAssertEqual(model.runtime.operations.last?.effect, "partial")
        XCTAssertNil(model.baseline)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.runtime.operations.count, 1)
    }

    func testMockDeduplicatesOperationIdsAndRejectsChangedPayload() async throws {
        let prefs = defaults()
        let drafts = StudioDraftStore(defaults: prefs)
        let config = drafts.configuration(modes: [.mode0])
        let mock = MockRuntimeClient(configuration: config, stepDelay: 1_000_000)
        _ = try await mock.connect()
        var request = ApplyConfiguration(operationId: "id", deviceId: "mock-x1", baseToken: "1", scope: .init(deviceFields: ["brightnessPercent"], modes: [0]), changes: config)
        let first = try await mock.apply(request)
        let second = try await mock.apply(request)
        XCTAssertEqual(first.operationId, second.operationId)
        request.changes.device.brightnessPercent = 99
        do { _ = try await mock.apply(request); XCTFail("Should reject changed payload") }
        catch { XCTAssertEqual(error as? RuntimeFailure, .remote("OPERATION_ID_CONFLICT")) }
    }

    func testEndpointRejectsRemoteHostsAndCredentialsInURL() throws {
        for url in ["ws://example.com:1234", "ws://127.0.0.1:1234?token=secret", "ws://user:pass@127.0.0.1:1234"] {
            XCTAssertThrowsError(try RuntimeEndpoint(endpoint: URL(string: url)!, token: "test").validate())
        }
        XCTAssertNoThrow(try RuntimeEndpoint(endpoint: URL(string: "ws://127.0.0.1:1234")!, token: "test").validate())
    }

    func testRealWebSocketClientAgainstPythonFixture() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repo.appendingPathComponent("scripts/mock-runtime-server.py").path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let path = try XCTUnwrap(String(data: output.fileHandleForReading.availableData, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = try RuntimeEndpoint.load(from: URL(fileURLWithPath: path))
        let client = IPCRuntimeClient(endpointProvider: { endpoint })
        defer { client.disconnect() }
        var events: [RuntimeEvent] = []
        client.onEvent = { events.append($0) }
        let session = try await client.connect()
        XCTAssertEqual(session.subscription.snapshot.sequence, "9007199254740993")
        let configuration = try await client.configuration(deviceId: "fixture-x1")
        XCTAssertEqual(configuration.configuration?.modes.count, 4)
        let data = try Data(contentsOf: repo.appendingPathComponent("contracts/runtime-v1/fixtures/apply.json"))
        let request = try JSONDecoder().decode(ApplyConfiguration.self, from: data)
        let accepted = try await client.apply(request)
        XCTAssertEqual(accepted.operationId, request.operationId)
        try await waitUntil { events.contains { $0.type == "operation.changed" } }
        let operation = try await client.operation(id: accepted.operationId)
        XCTAssertEqual(operation.status, "completed")
        let updated = try await client.configuration(deviceId: "fixture-x1")
        XCTAssertEqual(updated.configuration?.device.brightnessPercent, 60)
        XCTAssertEqual(updated.baseToken, "2")
    }

    func testLegacyDraftImportPreservesCustomKeysAndUsesGlobalBrightness() throws {
        var old = AhaKeyStudioDraft.default
        var mode = old.draft(for: .mode0)
        mode.lightBar.brightness = 54
        var key = mode.key(for: .approve)
        key.description = "My custom key"
        mode.updateKey(key)
        old.updateMode(mode)
        let prefs = defaults()
        let imported = StudioDraftStore(defaults: prefs, legacyDraft: try JSONEncoder().encode(old))
        XCTAssertEqual(imported.brightness, 54)
        XCTAssertEqual(imported.draft.draft(for: .mode0).key(for: .approve).description, "My custom key")
        imported.brightness = 86
        let restored = StudioDraftStore(defaults: prefs, legacyDraft: try JSONEncoder().encode(old))
        XCTAssertEqual(restored.brightness, 86, "Legacy data must only seed the first launch")
    }

    func testRestartWithMissingOperationKeepsResultUnknownAndDoesNotResend() async throws {
        let prefs = defaults()
        let drafts = StudioDraftStore(defaults: prefs)
        let configuration = drafts.configuration(modes: [.mode0])
        let request = ApplyConfiguration(operationId: "lost-operation", deviceId: "mock-x1", baseToken: "1", scope: .init(deviceFields: ["brightnessPercent"], modes: [0]), changes: configuration)
        prefs.set(try JSONEncoder().encode([request]), forKey: "studio.frontend.pending.v1")
        let mock = MockRuntimeClient(configuration: configuration)
        let model = StudioModel(client: mock, drafts: drafts, defaults: prefs, isMock: true)
        defer { model.stop() }
        model.start()
        try await waitUntil { model.unknownOperationIDs.contains(request.operationId) }
        XCTAssertEqual(model.pending.count, 1)
        XCTAssertTrue(model.runtime.operations.isEmpty)
        XCTAssertFalse(model.canApply)
        model.acknowledgeUnknownResult()
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertNil(model.baseline)
        XCTAssertFalse(model.canApply)
    }
}

@MainActor
private final class TestTransport: RPCTransport {
    var sent: [RPCValue] = []
    var onSend: ((RPCValue) -> Void)?
    private var incoming: [String] = []
    private var reader: CheckedContinuation<String, Error>?
    private var closed = false

    func send(_ text: String) async throws {
        let value = try JSONDecoder().decode(RPCValue.self, from: Data(text.utf8))
        sent.append(value)
        onSend?(value)
    }
    func receive() async throws -> String {
        if closed { throw RuntimeFailure.disconnected }
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func reply(_ value: RPCValue) {
        let text = String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
        if let reader { self.reader = nil; reader.resume(returning: text) }
        else { incoming.append(text) }
    }
    func close() {
        closed = true
        reader?.resume(throwing: RuntimeFailure.disconnected)
        reader = nil
    }
}

@MainActor
final class RPCConnectionTests: XCTestCase {
    func testResponsesCanArriveOutOfOrder() async throws {
        let transport = TestTransport()
        let connection = RPCConnection(transport: transport)
        connection.start()
        defer { connection.close() }
        transport.onSend = { _ in
            guard transport.sent.count == 2 else { return }
            for request in transport.sent.reversed() {
                transport.reply(.object(["jsonrpc": .string("2.0"), "id": request["id"]!, "result": request["method"]!]))
            }
        }
        async let first = connection.call("first", params: .object([:]), as: String.self)
        async let second = connection.call("second", params: .object([:]), as: String.self)
        let responses = try await (first, second)
        XCTAssertEqual(responses.0, "first")
        XCTAssertEqual(responses.1, "second")
    }

    func testTimeoutClosesSessionAndDoesNotResendWrite() async {
        let transport = TestTransport()
        let connection = RPCConnection(transport: transport, timeoutNanoseconds: 10_000_000)
        connection.start()
        do {
            let _: String = try await connection.call("configuration.apply", params: .object([:]), as: String.self)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? RuntimeFailure, .timeout) }
        XCTAssertEqual(transport.sent.count, 1)
    }

    func testRemoteErrorExposesStableCodeOnly() async {
        let transport = TestTransport()
        let connection = RPCConnection(transport: transport)
        connection.start()
        defer { connection.close() }
        transport.onSend = { request in
            transport.reply(.object([
                "jsonrpc": .string("2.0"), "id": request["id"]!,
                "error": .object(["code": .number(-32000), "message": .string("private backend details"), "data": .object(["code": .string("BASE_CONFLICT")])]),
            ]))
        }
        do {
            let _: String = try await connection.call("configuration.apply", params: .object([:]), as: String.self)
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? RuntimeFailure, .remote("BASE_CONFLICT")) }
    }
}
