import Foundation

@MainActor
protocol RuntimeClient: AnyObject {
    var onEvent: ((RuntimeEvent) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws -> RuntimeSession
    func disconnect()
    func configuration(deviceId: String) async throws -> ConfigurationDocument
    func apply(_ request: ApplyConfiguration) async throws -> OperationAccepted
    func operation(id: String) async throws -> RuntimeOperation
    func connectDevice(id: String) async throws
    func disconnectDevice(id: String) async throws
}
