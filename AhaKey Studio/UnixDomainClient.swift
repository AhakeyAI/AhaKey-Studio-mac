//
//  UnixDomainClint.swift
//  AhaKey Studio
//
//  Created by 龚浩天 on 4/9/26.
//

import Foundation
import Network

final class UnixDomainClient {
    
    private let connection: NWConnection
    private let queue: DispatchQueue
    
    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
        queue = DispatchQueue(label: "unix-labal")
    }
    
    func connect() {
        connection.stateUpdateHandler = { state in
            print("连接状态：\(state)")
        }
        connection.start(queue: queue)
    }
    
    func send(_ text: String) {
        connection.send(content: Data((text + "\n").utf8), completion: .contentProcessed { error in
            if let error {
                print("发送失败：\(error)")
            }
        })
    }
    
    func close() {
        connection.cancel()
    }
}
