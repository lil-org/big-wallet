import Foundation
import WalletDomain

struct AuthorityExecutionContext: Sendable {
    let handle: RequestHandle
    let executionID: UUID?
    let consentID: UUID?
    let enqueueAttempt: String
    let configurationKey: String
    let approvedAccount: WalletAccountDescriptor?
    let transaction: Transaction?
    let network: ResolvedEthereumNetwork?

    init(binding: ExtensionBridge.RequestBinding) {
        handle = binding.handle
        executionID = nil
        consentID = nil
        enqueueAttempt = binding.request.enqueueAttempt
        configurationKey = binding.request.configurationKey
        approvedAccount = binding.request.authorizedAccount
        transaction = nil
        network = nil
    }

    init(claim: ExtensionBridge.ApprovalClaim) {
        handle = claim.handle
        executionID = nil
        consentID = nil
        enqueueAttempt = claim.request.enqueueAttempt
        configurationKey = claim.request.configurationKey
        approvedAccount = claim.request.authorizedAccount
        transaction = nil
        network = nil
    }

    init(permit: ExtensionBridge.ApprovedExecutionPermit) {
        handle = permit.handle
        executionID = permit.executionID
        consentID = permit.approval.authorizationIdentifier
        enqueueAttempt = permit.request.enqueueAttempt
        configurationKey = permit.request.configurationKey
        approvedAccount = permit.approval.signingAccount
        if case .signing(_, .ethereumTransaction(let transaction, let network)) = permit.approval.kind {
            self.transaction = transaction
            self.network = network
        } else {
            transaction = nil
            network = nil
        }
    }

    @TaskLocal static var current: AuthorityExecutionContext?
}

struct AuthorityExecutionEvent: Sendable {
    enum Kind: String, Sendable {
        case requestAdmitted, consentAccepted, authorization, signingStarted, signingFinished
        case broadcastCheckpoint, broadcastDispatch, completion, authenticationCompleted, protectedKeyRead, vaultPublication
    }

    let kind: Kind
    let context: AuthorityExecutionContext?
    let handle: RequestHandle?
    let consentID: UUID?
    let account: WalletAccountDescriptor?
    let generation: UUID?
    let succeeded: Bool?
    let signingOutput: WalletSigningOutput?

    init(
        _ kind: Kind,
        context: AuthorityExecutionContext? = AuthorityExecutionContext.current,
        handle: RequestHandle? = nil,
        consentID: UUID? = nil,
        account: WalletAccountDescriptor? = nil,
        generation: UUID? = nil,
        succeeded: Bool? = nil,
        signingOutput: WalletSigningOutput? = nil
    ) {
        self.kind = kind
        self.context = context
        self.handle = handle ?? context?.handle
        self.consentID = consentID ?? context?.consentID
        self.account = account ?? context?.approvedAccount
        self.generation = generation
        self.succeeded = succeeded
        self.signingOutput = signingOutput
    }
}

struct AuthorityExecutionHooks: Sendable {
    enum Checkpoint: String, Sendable {
        case beforeAuthentication, beforeSigning, afterSigning
        case beforeCommitLease, afterCommitLease
        case beforeBroadcastCheckpoint, afterBroadcastCheckpoint, beforeDispatch, beforeCompletion
    }

    let checkpoint: @Sendable (Checkpoint, AuthorityExecutionContext?) async throws -> Void
    let event: @Sendable (AuthorityExecutionEvent) -> Void

    static let none = AuthorityExecutionHooks(checkpoint: { _, _ in }, event: { _ in })
    @TaskLocal static var current = AuthorityExecutionHooks.none

    static func reach(_ point: Checkpoint) async throws {
        try await current.checkpoint(point, AuthorityExecutionContext.current)
    }

    static func emit(_ event: AuthorityExecutionEvent) {
        current.event(event)
    }
}
