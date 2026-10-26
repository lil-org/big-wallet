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
    private let postCreation: @MainActor @Sendable () -> Void
#if os(iOS) || os(visionOS)
    private let vaultHost: SafariApprovalVaultHost

    init(keychain: Keychain, messages: AuthorityMessages, authorityID: UUID, vaultHost: SafariApprovalVaultHost, authentication: WalletCredentialAuthentication = .live, clock: @escaping @Sendable () -> Date = Date.init, postCreation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.keychain = keychain
        self.messages = messages
        self.authorityID = authorityID
        self.authentication = authentication
        self.clock = clock
        self.postCreation = postCreation
        self.vaultHost = vaultHost
    }
#else
    init(keychain: Keychain, messages: AuthorityMessages, authorityID: UUID, authentication: WalletCredentialAuthentication = .live, clock: @escaping @Sendable () -> Date = Date.init, postCreation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.keychain = keychain
        self.messages = messages
        self.authorityID = authorityID
        self.authentication = authentication
        self.clock = clock
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
        guard let storedPassword = try keychain.readPassword() else {
            throw WalletCredentialError.failedToRead(errSecItemNotFound)
        }
        var credential = Data(storedPassword.utf8)
        defer { credential.resetBytes(in: 0..<credential.count) }
        guard !Task.isCancelled, challenge.isPending(for: authorityID) else {
            challenge.invalidate()
            throw WalletCredentialError.authorizationUnavailable
        }
        guard storedPassword == password else { return nil }
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
        authorization.accessSession(authorityID: authorityID)
    }

    public func isCurrent(_ session: WalletAccessSession) -> Bool {
        session.isCurrent(for: authorityID)
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
        guard var credential = try keychain.readPasswordData() else { return nil }
        defer { credential.resetBytes(in: 0..<credential.count) }
        return issueGrant(for: challenge, verifiedCredential: credential)
    }

    private func issueGrant(for challenge: WalletAuthenticationChallenge, verifiedCredential credential: Data) -> WalletAuthenticationGrant? {
        let digest = Data(SHA256.hash(data: credential))
        let keychain = keychain
        return challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: {
            do {
                guard let current = try keychain.readPasswordData() else { return .changed }
                return Data(SHA256.hash(data: current)) == digest ? .current : .changed
            } catch {
                return .unavailable
            }
        }))
    }
}
