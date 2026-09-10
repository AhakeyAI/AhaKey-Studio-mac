import Foundation

let server = UnixDomainServer(socketPath: "/tmp/ahakey.sock")

do {
    try server.start()
    dispatchMain()
} catch {
    fputs("无法启动 Server：\(error)\n", stderr)
    exit(EXIT_FAILURE)
}
