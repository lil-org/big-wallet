import Foundation

public struct SolanaRPCEndpoint: Equatable, Hashable, Sendable {
    public let url: URL
    public let allowsAlchemyAuthorization: Bool

    public init(url: URL, allowsAlchemyAuthorization: Bool) {
        self.url = url
        self.allowsAlchemyAuthorization = allowsAlchemyAuthorization
    }
}

public protocol SolanaEndpointResolving: Sendable {
    func endpoint(for cluster: Solana.Cluster) -> SolanaRPCEndpoint?
}
