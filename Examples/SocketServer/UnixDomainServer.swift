//
//  UnixDomainServer.swift
//  AhaKey Studio
//
//  Created by 龚浩天 on 4/9/26.
//

import Foundation
import Network

final class UnixDomainServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "UnixDomainServer")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        // 删除上次异常退出遗留的 socket 文件
        try? FileManager.default.removeItem(atPath: socketPath)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                print("Server 已启动：\(socketPath)")

            case .failed(let error):
                print("Server 启动失败：\(error)")
                stop()

            case .cancelled:
                print("Server 已停止")

            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.cancel()
        }

        connections.removeAll()
        buffers.removeAll()
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        buffers[id] = Data()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }

            switch state {
            case .ready:
                print("Client 已连接")
                receive(from: connection)

            case .failed(let error):
                print("连接失败：\(error)")
                remove(connection)

            case .cancelled:
                remove(connection)

            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receive(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                let id = ObjectIdentifier(connection)
                guard var buffer = buffers[id] else { return }
                buffer.append(data)
                // Stream reads do not preserve message boundaries. Decode complete lines only.
                while let end = buffer.firstIndex(of: 0x0A) {
                    let message = String(decoding: buffer[..<end], as: UTF8.self)
                    buffer.removeSubrange(...end)
                    print("收到：\(message)")
                    send("Server 收到：\(message)\n", to: connection)
                }
                buffers[id] = buffer
            }

            if isComplete || error != nil {
                remove(connection)
            } else {
                // 继续等待同一个连接的下一批数据
                receive(from: connection)
            }
        }
    }

    private func send(
        _ message: String,
        to connection: NWConnection
    ) {
        connection.send(
            content: Data(message.utf8),
            completion: .contentProcessed { error in
                if let error {
                    print("发送失败：\(error)")
                }
            }
        )
    }

    private func remove(_ connection: NWConnection) {
        buffers.removeValue(forKey: ObjectIdentifier(connection))
        connections.removeValue(
            forKey: ObjectIdentifier(connection)
        )

        connection.cancel()
    }
}
