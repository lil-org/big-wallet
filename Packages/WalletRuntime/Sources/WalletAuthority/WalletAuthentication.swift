import Foundation
import Synchronization
import WalletDomain

public enum WalletSecretExport: Equatable, Sendable {
    case mnemonic, privateKey
}

struct WalletSecretExportBinding: Equatable, Sendable {
    let walletID: String
    let account: WalletAccountDescriptor?
    let kind: WalletSecretExport
    let sourceDigest: Data
    let credentialDigest: Data
}

struct TransactionAuthenticationBinding: Equatable, Sendable {
    let account: WalletAccountDescriptor
    let nonce: BigUInt
    let gasLimit: BigUInt
    let fee: PreparedTransactionFee
    let network: DappApprovalDecision.NetworkIdentity

    init(_ execution: DappApprovalDecision.TransactionExecution) {
        account = execution.approvedAccount
        nonce = execution.nonce
        gasLimit = execution.gasLimit
        fee = execution.fee
        network = execution.reviewedNetwork
    }
}

struct WalletCredentialIdentity: Sendable {
    enum Status: Equatable, Sendable { case current, changed, unavailable }
    let status: @Sendable () -> Status
}

public final class WalletAuthenticationChallenge: Sendable {
    enum Purpose: Equatable, Sendable {
        case walletAccess(UUID)
        case message(review: UUID, cluster: Solana.Cluster?)
        case transaction(review: UUID, binding: TransactionAuthenticationBinding)
        case secretExport(WalletSecretExportBinding)
    }

    private enum State: Sendable {
        case pending, issued(UUID), consumed, invalidated
    }

    let authorityID: UUID
    let purpose: Purpose
    private let deadline: Date
    private let clock: @Sendable () -> Date
    private let state = Mutex(State.pending)

    init(authorityID: UUID, purpose: Purpose, deadline: Date, clock: @escaping @Sendable () -> Date = Date.init) {
        self.authorityID = authorityID
        self.purpose = purpose
        self.deadline = deadline
        self.clock = clock
    }

    func isPending(for authorityID: UUID, at date: Date? = nil) -> Bool {
        let now = date ?? clock()
        guard self.authorityID == authorityID, lifetimeIsCurrent(at: now) else { return false }
        return state.withLock {
            if case .pending = $0 { return true }
            return false
        }
    }

    func issueGrant(
        for authorityID: UUID,
        at date: Date? = nil,
        credentialIdentity: WalletCredentialIdentity
    ) -> WalletAuthenticationGrant? {
        let now = date ?? clock()
        guard self.authorityID == authorityID, lifetimeIsCurrent(at: now), credentialIdentity.status() == .current else { return nil }
        let identifier = UUID()
        let issued = state.withLock { state in
            guard case .pending = state else { return false }
            state = .issued(identifier)
            return true
        }
        guard issued else { return nil }
        return WalletAuthenticationGrant(challenge: self, identifier: identifier, credentialIdentity: credentialIdentity)
    }

    fileprivate func consume(_ grant: WalletAuthenticationGrant, at date: Date? = nil) -> Bool {
        let now = date ?? clock()
        guard grant.challenge === self, lifetimeIsCurrent(at: now) else { return false }
        return state.withLock { state in
            guard case .issued(let identifier) = state, identifier == grant.identifier else { return false }
            state = .consumed
            return true
        }
    }

    public func invalidate() {
        state.withLock { $0 = .invalidated }
    }

    private func lifetimeIsCurrent(at date: Date) -> Bool {
        guard date < deadline else {
            invalidate()
            return false
        }
        return true
    }
}

public final class WalletAuthenticationGrant: Sendable {
    fileprivate let challenge: WalletAuthenticationChallenge
    fileprivate let identifier: UUID
    fileprivate let credentialIdentity: WalletCredentialIdentity

    fileprivate init(
        challenge: WalletAuthenticationChallenge,
        identifier: UUID,
        credentialIdentity: WalletCredentialIdentity
    ) {
        self.challenge = challenge
        self.identifier = identifier
        self.credentialIdentity = credentialIdentity
    }

    func consume(
        authorityID: UUID,
        purpose: WalletAuthenticationChallenge.Purpose,
        at date: Date? = nil
    ) -> Bool {
        guard challenge.authorityID == authorityID,
              challenge.purpose == purpose,
              credentialIdentity.status() == .current else {
            invalidate()
            return false
        }
        return challenge.consume(self, at: date)
    }

    func consumeExport(
        authorityID: UUID,
        walletID: String,
        account: WalletAccountDescriptor?,
        kind: WalletSecretExport
    ) -> WalletSecretExportBinding? {
        guard case .secretExport(let binding) = challenge.purpose,
              binding.walletID == walletID, binding.account == account, binding.kind == kind,
              consume(authorityID: authorityID, purpose: .secretExport(binding)) else { return nil }
        return binding
    }

    func accessSession(authorityID: UUID) -> WalletAccessSession? {
        guard case .walletAccess = challenge.purpose,
              consume(authorityID: authorityID, purpose: challenge.purpose) else { return nil }
        return WalletAccessSession(authorityID: authorityID, credentialIdentity: credentialIdentity)
    }

    public func invalidate() {
        challenge.invalidate()
    }
}

public final class WalletAccessSession: Sendable {
    private let authorityID: UUID
    private let credentialIdentity: WalletCredentialIdentity
    private let active = Mutex(true)

    fileprivate init(authorityID: UUID, credentialIdentity: WalletCredentialIdentity) {
        self.authorityID = authorityID
        self.credentialIdentity = credentialIdentity
    }

    func isCurrent(for authorityID: UUID) -> Bool {
        status(for: authorityID) == .current
    }

    func permitsAuthenticatedPresentation(for authorityID: UUID) -> Bool {
        status(for: authorityID) != .changed
    }

    private func status(for authorityID: UUID) -> WalletCredentialIdentity.Status {
        guard self.authorityID == authorityID, active.withLock({ $0 }) else { return .changed }
        let status = credentialIdentity.status()
        if status == .changed {
            invalidate()
            return .changed
        }
        return active.withLock { $0 } ? status : .changed
    }

    public func invalidate() {
        active.withLock { $0 = false }
    }
}

public enum WalletAuthenticationResult: Sendable {
    case granted(WalletAuthenticationGrant)
    case failed
    case interactionUnavailable
}
