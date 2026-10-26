import Foundation

public struct RPCScope: Hashable, Sendable {
    public let profileIdentifier: UUID?
    public let origin: String

    public init(profileIdentifier: UUID?, origin: String) {
        self.profileIdentifier = profileIdentifier
        self.origin = origin
    }
}

public protocol PublicRPCForwarding: Sendable {
    func forward(id: Int, chainId: String, body: String, scope: RPCScope) async -> RPCResponseToExtension
}
