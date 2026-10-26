import Foundation

public struct RPCResponseToExtension: Sendable {
    public let id: Int
    public let wire: WireProtocol.ValidatedObject

    public init?(upstream: [String: Any], expectedResponseID: Int) {
        var envelope = [String: Any]()
        envelope["id"] = upstream["id"]
        envelope["jsonrpc"] = upstream["jsonrpc"]
        envelope["result"] = upstream["result"]
        envelope["error"] = upstream["error"]
        guard let id = envelope["id"] as? Int, id == expectedResponseID,
              let wire = WireProtocol.object(.rpcResponse, value: envelope) else { return nil }
        self.id = id
        self.wire = wire
    }

    public var json: [String: Any] { wire.json }
}
