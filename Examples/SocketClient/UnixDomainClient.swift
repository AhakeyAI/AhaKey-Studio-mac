import Foundation
import Network

final class UnixDomainClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "unix-socket-client")
    private let onMessage: (String) -> Void
    private let onDisconnect: (Error?) -> Void
    private var buffer = Data()

    init(path: String, onMessage: @escaping (String) -> Void,
         onDisconnect: @escaping (Error?) -> Void) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func connect(onReady: @escaping () -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("连接已就绪")
                receive()
                onReady()
            case .waiting(let error):
                print("等待连接：\(error)")
            case .failed(let error):
                connection.stateUpdateHandler = nil
                connection.cancel()
                onDisconnect(error)
            case .cancelled:
                onDisconnect(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ text: String) {
        connection.send(content: Data((text + "\n").utf8),
                        completion: .contentProcessed { error in
            if let error { print("发送失败：\(error)") }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            // 每行是一条消息；收齐之后再解码，避免拆开中文字符。
            while let end = buffer.firstIndex(of: 0x0A) {
                let message = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeSubrange(...end)
                onMessage(message)
            }
            if let error { print("接收失败：\(error)") }
            if isComplete || error != nil {
                close()
            } else {
                receive()
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
