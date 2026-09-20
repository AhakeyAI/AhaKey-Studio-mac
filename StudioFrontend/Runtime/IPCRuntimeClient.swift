import Foundation
import Darwin

struct RuntimeEndpoint: Codable {
    let endpoint: URL
    let token: String

    static func load(from url: URL) throws -> Self {
        // Do not accept a discovery file readable/writable by other users.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 16_384 else {
            throw RuntimeFailure.invalidEndpoint
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func validate() throws {
        guard endpoint.scheme == "ws",
              ["127.0.0.1", "[::1]", "::1"].contains(endpoint.host ?? ""),
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              !token.isEmpty else { throw RuntimeFailure.invalidEndpoint }
    }

    static var discoveryURL: URL {
        if let path = ProcessInfo.processInfo.environment["AHAKEY_RUNTIME_DISCOVERY"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AhaKey/runtime/discovery.json")
    }
}

@MainActor
protocol RPCTransport: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor
final class WebSocketTransport: RPCTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask

    init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        socket.resume()
    }

    func send(_ text: String) async throws { try await socket.send(.string(text)) }
    func receive() async throws -> String {
        guard case .string(let text) = try await socket.receive() else { throw RuntimeFailure.invalidMessage }
        return text
    }
    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// One receive loop, serialized sends, bounded pending calls. Writes are never replayed here.
@MainActor
final class RPCConnection {
    var onNotification: ((String, RPCValue) throws -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private let transport: RPCTransport
    private let timeoutNanoseconds: UInt64
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var queue: [(String, String)] = []
    private var pending: [String: CheckedContinuation<RPCValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var closed = false

    init(transport: RPCTransport, timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.transport = transport
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func start() {
        reader = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let text = try await transport.receive()
                    guard let self, !self.closed else { return }
                    try self.receive(text)
                }
            } catch {
                self?.close(error: error, notify: true)
            }
        }
    }

    func call<T: Decodable>(_ method: String, params: RPCValue, as type: T.Type) async throws -> T {
        guard !closed else { throw RuntimeFailure.disconnected }
        guard pending.count < 32 else { throw RuntimeFailure.remote("BUSY") }
        let id = UUID().uuidString
        let message = RPCValue.object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "method": .string(method), "params": params,
        ])
        let data = try JSONEncoder().encode(message)
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw RuntimeFailure.invalidMessage
        }
        let result: RPCValue = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self, timeoutNanoseconds] in
                do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                // A missing response makes the session uncertain. Reconnect for a fresh snapshot.
                self?.close(error: RuntimeFailure.timeout, notify: true)
            }
            queue.append((id, text))
            drain()
        }
        return try result.decoded(type)
    }

    private func drain() {
        guard sender == nil else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            defer { self.sender = nil }
            do {
                while !self.queue.isEmpty && !self.closed {
                    let (id, text) = self.queue.removeFirst()
                    if self.pending[id] != nil { try await self.transport.send(text) }
                }
            } catch { self.close(error: error, notify: true) }
        }
    }

    private func receive(_ text: String) throws {
        guard text.utf8.count <= 1_048_576 else { throw RuntimeFailure.invalidMessage }
        let value = try JSONDecoder().decode(RPCValue.self, from: Data(text.utf8))
        guard value["jsonrpc"]?.string == "2.0" else { throw RuntimeFailure.invalidMessage }
        if let id = value["id"]?.string {
            guard (value["result"] != nil) != (value["error"] != nil) else { throw RuntimeFailure.invalidMessage }
            guard let continuation = pending.removeValue(forKey: id) else { return }
            deadlines.removeValue(forKey: id)?.cancel()
            if let error = value["error"] {
                // Stable error code only; do not echo arbitrary backend text or credentials into UI.
                let fallback: String
                switch error["code"] {
                case .number(-32602): fallback = "INVALID_PARAMS"
                case .number(-32601): fallback = "UNSUPPORTED_CAPABILITY"
                default: fallback = "RPC_ERROR"
                }
                continuation.resume(throwing: RuntimeFailure.remote(error["data"]?["code"]?.string ?? fallback))
            } else { continuation.resume(returning: value["result"]!) }
        } else if let method = value["method"]?.string {
            try onNotification?(method, value["params"] ?? .null)
        } else { throw RuntimeFailure.invalidMessage }
    }

    func close(error: Error = RuntimeFailure.disconnected, notify: Bool = false) {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        sender?.cancel()
        transport.close()
        queue.removeAll()
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let calls = pending.values
        pending.removeAll()
        for call in calls { call.resume(throwing: error) }
        if notify { onDisconnect?(error) }
    }
}

@MainActor
final class IPCRuntimeClient: RuntimeClient {
    var onEvent: ((RuntimeEvent) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private var connection: RPCConnection?
    private var methods: Set<String> = []
    private let endpointProvider: () throws -> RuntimeEndpoint

    init(endpointProvider: @escaping () throws -> RuntimeEndpoint = { try RuntimeEndpoint.load(from: RuntimeEndpoint.discoveryURL) }) {
        self.endpointProvider = endpointProvider
    }

    func connect() async throws -> RuntimeSession {
        disconnect()
        let endpoint = try endpointProvider()
        try endpoint.validate()
        let connection = RPCConnection(transport: WebSocketTransport(url: endpoint.endpoint))
        self.connection = connection
        connection.onNotification = { [weak self, weak connection] method, params in
            guard let self, self.connection === connection else { return }
            if method == "runtime.event" { self.onEvent?(try params.decoded(RuntimeEvent.self)) }
        }
        connection.onDisconnect = { [weak self, weak connection] error in
            guard let self, self.connection === connection else { return }
            self.onDisconnect?(error)
        }
        connection.start()
        do {
            let hello = try await connection.call("runtime.hello", params: .object([
                "protocol": .object(["major": .number(1), "minor": .number(0)]),
                "client": .object(["name": .string("AhaKey Studio"), "version": .string("0.1.0"), "kind": .string("studio")]),
                "token": .string(endpoint.token),
            ]), as: RuntimeHello.self)
            guard hello.protocol.major == 1 else { throw RuntimeFailure.incompatibleProtocol }
            methods = Set(hello.methods)
            let subscription: RuntimeSubscription = try await call("runtime.subscribe", params: .object([
                "topics": .array([.string("state")]), "cursor": .null,
            ]))
            guard subscription.snapshot.instanceId == hello.instanceId else { throw RuntimeFailure.invalidMessage }
            return RuntimeSession(hello: hello, subscription: subscription)
        } catch {
            if self.connection === connection { disconnect() }
            throw error
        }
    }

    func disconnect() {
        connection?.onDisconnect = nil
        connection?.onNotification = nil
        connection?.close()
        connection = nil
        methods = []
    }

    private func call<T: Decodable>(_ method: String, params: RPCValue) async throws -> T {
        guard let connection else { throw RuntimeFailure.disconnected }
        guard methods.contains(method) else { throw RuntimeFailure.unsupported(method) }
        return try await connection.call(method, params: params, as: T.self)
    }

    func configuration(deviceId: String) async throws -> ConfigurationDocument {
        try await call("configuration.get", params: .object(["deviceId": .string(deviceId)]))
    }
    func apply(_ request: ApplyConfiguration) async throws -> OperationAccepted {
        try await call("configuration.apply", params: .encoded(request))
    }
    func operation(id: String) async throws -> RuntimeOperation {
        try await call("operation.get", params: .object(["operationId": .string(id)]))
    }
    func connectDevice(id: String) async throws {
        let _: RPCValue = try await call("device.connect", params: .object(["deviceId": .string(id)]))
    }
    func disconnectDevice(id: String) async throws {
        let _: RPCValue = try await call("device.disconnect", params: .object(["deviceId": .string(id)]))
    }
}
