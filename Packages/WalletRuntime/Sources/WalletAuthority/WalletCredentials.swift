import Foundation
import Security
import CryptoKit

public enum WalletCredentialError: Error {
    case failedToRead(OSStatus)
    case failedToSave(OSStatus)
    case failedToUpdate
    case failedToDelete(OSStatus)
    case invalidPasswordData
    case orphanedWallets
    case authorizationUnavailable
}

public enum WalletPasswordState: Equatable, Sendable { case missing, present }
public enum WalletPasswordCreationResult: Equatable, Sendable { case created, alreadyExists }
public enum WalletAuthenticationOutcome: Equatable, Sendable {
    case succeeded, failed, interactionUnavailable
}

struct WalletCredentialAuthentication: Sendable {
    let canUseBiometrics: @Sendable () -> Bool
    let attemptBiometrics: @MainActor @Sendable (String) async -> WalletAuthenticationOutcome

    static let live = WalletCredentialAuthentication(
        canUseBiometrics: { DeviceAuthentication.canUseBiometrics },
        attemptBiometrics: { await DeviceAuthentication.attemptBiometrics(reason: $0) }
    )
}

public struct WalletCredentials: Sendable {
    private let keychain: Keychain
    private let messages: AuthorityMessages
    private let authorityID: UUID
    private let authentication: WalletCredentialAuthentication
    private let clock: @Sendable () -> Date
    private let accessClock: @Sendable () -> ContinuousClock.Instant
    private let postCreation: @MainActor @Sendable () -> Void
#if os(iOS) || os(visionOS)
    private let vaultHost: SafariApprovalVaultHost

    init(keychain: Keychain, messages: AuthorityMessages, authorityID: UUID, vaultHost: SafariApprovalVaultHost, authentication: WalletCredentialAuthentication = .live, clock: @escaping @Sendable () -> Date = Date.init, accessClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, postCreation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.keychain = keychain
        self.messages = messages
        self.authorityID = authorityID
        self.authentication = authentication
        self.clock = clock
        self.accessClock = accessClock
        self.postCreation = postCreation
        self.vaultHost = vaultHost
    }
#else
    init(keychain: Keychain, messages: AuthorityMessages, authorityID: UUID, authentication: WalletCredentialAuthentication = .live, clock: @escaping @Sendable () -> Date = Date.init, accessClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, postCreation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.keychain = keychain
        self.messages = messages
        self.authorityID = authorityID
        self.authentication = authentication
        self.clock = clock
        self.accessClock = accessClock
        self.postCreation = postCreation
    }
#endif

    public func passwordState() throws -> WalletPasswordState {
        try keychain.passwordState()
    }

    public func createPasswordIfMissing(_ password: String) async throws -> WalletPasswordCreationResult {
        let result: WalletPasswordCreationResult
#if os(iOS) || os(visionOS)
        result = try await vaultHost.performSourceMutation { willMutate in
            try keychain.createPasswordIfMissing(password, beforeInsert: willMutate)
        }
#else
        result = try keychain.createPasswordIfMissing(password, beforeInsert: {})
#endif
        if result == .created { await postCreation() }
        return result
    }

    public func makeWalletAccessChallenge() -> WalletAuthenticationChallenge {
        WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: .walletAccess(UUID()),
            deadline: clock().addingTimeInterval(ExtensionBridge.executionLifetime), clock: clock
        )
    }

    public func verify(password: String, challenge: WalletAuthenticationChallenge) throws -> WalletAuthenticationGrant? {
        guard !Task.isCancelled, challenge.isPending(for: authorityID) else {
            challenge.invalidate()
            throw WalletCredentialError.authorizationUnavailable
        }
        guard let credential = try keychain.readPasswordSecret() else {
            throw WalletCredentialError.failedToRead(errSecItemNotFound)
        }
        defer { credential.invalidate() }
        guard !Task.isCancelled, challenge.isPending(for: authorityID) else {
            challenge.invalidate()
            throw WalletCredentialError.authorizationUnavailable
        }
        guard try credential.matchesUTF8String(password) else { return nil }
        guard !Task.isCancelled, let grant = issueGrant(for: challenge, verifiedCredential: credential) else {
            challenge.invalidate()
            throw WalletCredentialError.authorizationUnavailable
        }
        guard !Task.isCancelled else {
            grant.invalidate()
            throw WalletCredentialError.authorizationUnavailable
        }
        return grant
    }

    public func accessSession(authorization: WalletAuthenticationGrant) -> WalletAccessSession? {
        authorization.accessSession(authorityID: authorityID, accessClock: accessClock)
    }

    public func validateAccess(_ session: WalletAccessSession) -> Bool {
        session.validateCredentials(for: authorityID)
    }

    public func permitsAuthenticatedPresentation(_ session: WalletAccessSession) -> Bool {
        session.permitsAuthenticatedPresentation(for: authorityID)
    }

    public func recordInteraction(_ session: WalletAccessSession) -> Duration? {
        session.recordInteraction(for: authorityID)
    }

    public func remainingAccessLifetime(_ session: WalletAccessSession) -> Duration? {
        session.remainingLifetime(for: authorityID)
    }

    public var canUseBiometrics: Bool { authentication.canUseBiometrics() }

    @MainActor
    public func attemptBiometrics(reason: String, challenge: WalletAuthenticationChallenge) async -> WalletAuthenticationResult {
        guard !Task.isCancelled, challenge.isPending(for: authorityID) else { return .failed }
        let outcome = await AuthorityMessageContext.$current.withValue(messages) {
            await authentication.attemptBiometrics(reason)
        }
        guard !Task.isCancelled, challenge.isPending(for: authorityID) else { return .failed }
        switch outcome {
        case .succeeded:
            guard let grant = try? issueGrant(for: challenge) else { return .failed }
            guard !Task.isCancelled else { grant.invalidate(); return .failed }
            return .granted(grant)
        case .failed: return .failed
        case .interactionUnavailable: return .interactionUnavailable
        }
    }

    private func issueGrant(for challenge: WalletAuthenticationChallenge) throws -> WalletAuthenticationGrant? {
        guard let credential = try keychain.readPasswordSecret() else { return nil }
        defer { credential.invalidate() }
        return issueGrant(for: challenge, verifiedCredential: credential)
    }

    private func issueGrant(for challenge: WalletAuthenticationChallenge, verifiedCredential credential: SecretBytes) -> WalletAuthenticationGrant? {
        guard let digest = try? credential.sha256Digest() else { return nil }
        let keychain = keychain
        return challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: {
            do {
                guard let current = try keychain.readPasswordSecret() else { return .changed }
                defer { current.invalidate() }
                return try current.sha256Digest() == digest ? .current : .changed
            } catch {
                return .unavailable
            }
        }))
    }
}
