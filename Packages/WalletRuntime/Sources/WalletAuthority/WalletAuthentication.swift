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
    static let standaloneLifetime = Duration.seconds(150)
    private let deadline: ContinuousClock.Instant
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let requestDeadline: Date?
    private let requestClock: @Sendable () -> Date
    private let state = Mutex(State.pending)

    init(
        authorityID: UUID,
        purpose: Purpose,
        deadline: ContinuousClock.Instant,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        requestDeadline: Date? = nil,
        requestClock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authorityID = authorityID
        self.purpose = purpose
        self.deadline = deadline
        self.clock = clock
        self.requestDeadline = requestDeadline
        self.requestClock = requestClock
    }

    func isPending(for authorityID: UUID) -> Bool {
        guard self.authorityID == authorityID else { return false }
        return state.withLock { state in
            guard lifetimeIsCurrent(state: &state) else { return false }
            if case .pending = state { return true }
            return false
        }
    }

    func issueGrant(
        for authorityID: UUID,
        credentialIdentity: WalletCredentialIdentity
    ) -> WalletAuthenticationGrant? {
        guard isPending(for: authorityID), credentialIdentity.status() == .current else { return nil }
        let identifier = UUID()
        let issued = state.withLock { state in
            guard lifetimeIsCurrent(state: &state), case .pending = state else { return false }
            state = .issued(identifier)
            return true
        }
        guard issued else { return nil }
        return WalletAuthenticationGrant(challenge: self, identifier: identifier, credentialIdentity: credentialIdentity)
    }

    fileprivate func consume(_ grant: WalletAuthenticationGrant) -> Bool {
        guard grant.challenge === self else { return false }
        return state.withLock { state in
            guard lifetimeIsCurrent(state: &state),
                  case .issued(let identifier) = state, identifier == grant.identifier else { return false }
            state = .consumed
            return true
        }
    }

    public func invalidate() {
        state.withLock { $0 = .invalidated }
    }

    private func lifetimeIsCurrent(state: inout State) -> Bool {
        guard clock() < deadline,
              requestDeadline.map({ requestClock() < $0 }) ?? true else {
            state = .invalidated
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
        purpose: WalletAuthenticationChallenge.Purpose
    ) -> Bool {
        guard challenge.authorityID == authorityID,
              challenge.purpose == purpose,
              credentialIdentity.status() == .current else {
            invalidate()
            return false
        }
        return challenge.consume(self)
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

    func accessSession(
        authorityID: UUID,
        accessClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) -> WalletAccessSession? {
        guard case .walletAccess = challenge.purpose,
              consume(authorityID: authorityID, purpose: challenge.purpose) else { return nil }
        return WalletAccessSession(authorityID: authorityID, credentialIdentity: credentialIdentity, clock: accessClock)
    }

    public func invalidate() {
        challenge.invalidate()
    }
}

public final class WalletAccessSession: Sendable {
    private static let inactivityLifetime = Duration.seconds(15 * 60)
    private let authorityID: UUID
    private let credentialIdentity: WalletCredentialIdentity
    private let clock: @Sendable () -> ContinuousClock.Instant
    private struct State {
        var deadline: ContinuousClock.Instant?
        var invalidationObservers = [UUID: @Sendable () -> Void]()
    }
    private let state: Mutex<State>

    fileprivate init(
        authorityID: UUID,
        credentialIdentity: WalletCredentialIdentity,
        clock: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.authorityID = authorityID
        self.credentialIdentity = credentialIdentity
        self.clock = clock
        state = Mutex(State(deadline: clock() + Self.inactivityLifetime))
    }

    func validateCredentials(for authorityID: UUID) -> Bool {
        guard remainingLifetime(for: authorityID) != nil else { return false }
        let status = credentialIdentity.status()
        if status == .changed { invalidate() }
        return remainingLifetime(for: authorityID) != nil && status == .current
    }

    func permitsAuthenticatedPresentation(for authorityID: UUID) -> Bool {
        remainingLifetime(for: authorityID) != nil
    }

    func recordInteraction(for authorityID: UUID) -> Duration? {
        guard self.authorityID == authorityID else { return nil }
        let recorded = state.withLock { state in
            let now = clock()
            guard let current = state.deadline, now < current else { return false }
            state.deadline = now + Self.inactivityLifetime
            return true
        }
        if !recorded { invalidate() }
        return recorded ? Self.inactivityLifetime : nil
    }

    func remainingLifetime(for authorityID: UUID) -> Duration? {
        guard self.authorityID == authorityID else { return nil }
        return remainingLifetime()
    }

    private func remainingLifetime() -> Duration? {
        let remaining = state.withLock { state -> Duration? in
            let now = clock()
            guard let current = state.deadline, now < current else { return nil }
            return now.duration(to: current)
        }
        if remaining == nil { invalidate() }
        return remaining
    }

    func observeInvalidation(for authorityID: UUID, _ observer: @escaping @Sendable () -> Void) -> UUID? {
        guard self.authorityID == authorityID else { observer(); return nil }
        let identifier = UUID()
        let installed = state.withLock { state in
            guard let deadline = state.deadline, clock() < deadline else { return false }
            state.invalidationObservers[identifier] = observer
            return true
        }
        guard installed else { invalidate(); observer(); return nil }
        return identifier
    }

    func removeInvalidationObserver(_ identifier: UUID) {
        state.withLock { $0.invalidationObservers[identifier] = nil }
    }

    public func invalidate() {
        let observers = state.withLock { state in
            state.deadline = nil
            let observers = Array(state.invalidationObservers.values)
            state.invalidationObservers.removeAll()
            return observers
        }
        for observer in observers { observer() }
    }

    deinit { invalidate() }
}

public enum WalletAuthenticationResult: Sendable {
    case granted(WalletAuthenticationGrant)
    case failed
    case interactionUnavailable
}
