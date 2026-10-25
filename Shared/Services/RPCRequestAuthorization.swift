import Foundation
import Synchronization

struct RPCRequestAuthorization: Sendable {
    private let url: URL
    private let allowsAlchemyAuthorization: Bool
    private let provider: any AlchemyAuthorizationProviding
    private let unauthorizedRecovery = OneShotGate()

    init(
        url: URL,
        allowsAlchemyAuthorization: Bool,
        provider: any AlchemyAuthorizationProviding
    ) {
        self.url = url
        self.allowsAlchemyAuthorization = allowsAlchemyAuthorization
        self.provider = provider
    }

    func acquire() async throws -> AlchemyAuthorization? {
        guard allowsAlchemyAuthorization else { return nil }
        return try await provider.authorization(for: url)
    }

    func reserveUnauthorizedRecovery() -> Bool {
        allowsAlchemyAuthorization && unauthorizedRecovery.claim()
    }

    func replacement(afterUnauthorized rejected: AlchemyAuthorization) async throws -> AlchemyAuthorization? {
        guard allowsAlchemyAuthorization else { return nil }
        return try await provider.replacementAuthorization(afterUnauthorized: rejected, for: url)
    }

    func invalidate(afterUnauthorized rejected: AlchemyAuthorization) async {
        guard allowsAlchemyAuthorization else { return }
        await provider.invalidateAuthorization(afterUnauthorized: rejected, for: url)
    }
}

final class OneShotGate: Sendable {
    private let isAvailable = Mutex(true)

    func claim() -> Bool {
        isAvailable.withLock { available in
            guard available else { return false }
            available = false
            return true
        }
    }
}
