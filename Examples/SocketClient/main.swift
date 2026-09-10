import Foundation

let client = UnixDomainClient(
    path: "/tmp/ahakey.sock",
    onMessage: { message in
        print("收到回复：\(message)")
    },
    onDisconnect: { error in
        if let error {
            print("连接结束：\(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
        print("连接已关闭")
        exit(EXIT_SUCCESS)
    }
)

client.connect {
    client.send("Hello, world")
    client.send("第二条消息")
}

// 保持运行、持续接收。不再需要通信时才调用 client.close()。
dispatchMain()
