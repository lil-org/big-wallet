import Foundation
import WalletDomain
import Synchronization

public struct RPCRequestAuthorization: Sendable {
    private let url: URL
    private let allowsAlchemyAuthorization: Bool
    private let provider: any AlchemyAuthorizationProviding
    private let unauthorizedRecovery = OneShotGate()

    public init(
        url: URL,
        allowsAlchemyAuthorization: Bool,
        provider: any AlchemyAuthorizationProviding
    ) {
        self.url = url
        self.allowsAlchemyAuthorization = allowsAlchemyAuthorization
        self.provider = provider
    }

    public func acquire() async throws -> AlchemyAuthorization? {
        guard allowsAlchemyAuthorization else { return nil }
        return try await provider.authorization(for: url)
    }

    public func reserveUnauthorizedRecovery() -> Bool {
        allowsAlchemyAuthorization && unauthorizedRecovery.claim()
    }

    public func replacement(afterUnauthorized rejected: AlchemyAuthorization) async throws -> AlchemyAuthorization? {
        guard allowsAlchemyAuthorization else { return nil }
        return try await provider.replacementAuthorization(afterUnauthorized: rejected, for: url)
    }

    public func invalidate(afterUnauthorized rejected: AlchemyAuthorization) async {
        guard allowsAlchemyAuthorization else { return }
        await provider.invalidateAuthorization(afterUnauthorized: rejected, for: url)
    }
}

public final class OneShotGate: Sendable {
    private let isAvailable = Mutex(true)

    public init() {}

    public func claim() -> Bool {
        isAvailable.withLock { available in
            guard available else { return false }
            available = false
            return true
        }
    }
}
