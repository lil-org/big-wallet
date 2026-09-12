// ∅ 2026 lil org

import Foundation

@MainActor
protocol PopupRequestProcessing {
    func prepare(_ request: SafariRequest) -> DappRequestPreparation
    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation
    func prepareWithoutWallets(_ request: SafariRequest) -> DappRequestPreparation?
}

extension PopupRequestProcessing {
    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        prepare(request)
    }

    func prepareWithoutWallets(_ request: SafariRequest) -> DappRequestPreparation? {
        return nil
    }
}

struct ProductionPopupRequestProcessor: PopupRequestProcessing {
    func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        return DappRequestProcessor.prepare(request)
    }

    func prepare(
        _ request: SafariRequest,
        walletAccess: WalletAccess
    ) -> DappRequestPreparation {
        DappRequestProcessor.prepare(request, walletAccess: walletAccess)
    }

    func prepareWithoutWallets(_ request: SafariRequest) -> DappRequestPreparation? {
        return DappRequestProcessor.prepareWithoutWallets(request)
    }
}

enum DappAdmissionDisposition: Equatable, Sendable {
    case approvalRequired
    case responseReady
    case unavailable
}

@MainActor
final class PopupRequestSession {

    enum Kind: String {
        case selectAccount, switchAccount, signMessage, sendTransaction, addChain
    }

    enum State: String {
        case review, authenticating, working, error
    }

    enum Purpose {
        case approval(DappRequestAction)
        case immediateResponsePersistence
    }

    private enum Lifecycle {
        case review(feedback: String?)
        case claiming
        case working(ApprovalContext)
        case authenticating(ApprovalContext)
        case persistingImmediateResponse
        case error(message: String)
    }

    private struct ApprovalContext {
        let claim: ExtensionBridge.ApprovalClaim
        var feedback: String?
        var reviewRecovery: ReviewRecovery = .reuse
    }

    private enum ReviewRecovery {
        case reuse
        case rematerialize
    }

    let handle: ExtensionBridge.Handle
    let request: SafariRequest
    var walletAccess: WalletAccess?
    private(set) var purpose: Purpose
    var transaction: PopupTransactionSession?
    private var lifecycle: Lifecycle
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0

    init(
        handle: ExtensionBridge.Handle,
        request: SafariRequest,
        purpose: Purpose,
        walletAccess: WalletAccess? = nil
    ) {
        self.handle = handle
        self.request = request
        self.purpose = purpose
        self.walletAccess = walletAccess
        switch purpose {
        case .approval:
            lifecycle = .review(feedback: nil)
        case .immediateResponsePersistence:
            lifecycle = .persistingImmediateResponse
        }
    }

    var state: State {
        switch lifecycle {
        case .review:
            return .review
        case .claiming, .working, .persistingImmediateResponse:
            return .working
        case .authenticating:
            return .authenticating
        case .error:
            return .error
        }
    }

    var approvalClaim: ExtensionBridge.ApprovalClaim? {
        switch lifecycle {
        case .working(let context), .authenticating(let context):
            return context.claim
        case .review, .claiming, .persistingImmediateResponse, .error:
            return nil
        }
    }

    var errorText: String? {
        switch lifecycle {
        case .review(let feedback):
            return feedback
        case .working(let context), .authenticating(let context):
            return context.feedback
        case .error(let message):
            return message
        case .claiming, .persistingImmediateResponse:
            return nil
        }
    }

    func setFeedback(_ message: String) {
        switch lifecycle {
        case .review:
            lifecycle = .review(feedback: message)
        case .working, .authenticating:
            updateApprovalContext { $0.feedback = message }
        case .error:
            lifecycle = .error(message: message)
        case .claiming, .persistingImmediateResponse:
            break
        }
    }

    var approvalAction: DappRequestAction? {
        guard case .approval(let action) = purpose else { return nil }
        return action
    }

    var isImmediateResponsePersistence: Bool {
        guard case .immediateResponsePersistence = purpose else { return false }
        return true
    }

    func replaceSelectionAction(_ action: SelectAccountAction) -> Bool {
        switch purpose {
        case .approval(.selectAccount):
            purpose = .approval(.selectAccount(action))
            return true
        case .approval(.switchAccount):
            purpose = .approval(.switchAccount(action))
            return true
        default:
            return false
        }
    }

    var canBeginApproval: Bool {
        return state == .review
    }

    func beginApproval() -> UUID? {
        guard case .review = lifecycle else { return nil }
        lifecycle = .claiming
        reviewToken = UUID()
        return reviewToken
    }

    func isCurrent(_ token: UUID) -> Bool {
        return reviewToken == token
    }

    func acceptClaim(
        _ claim: ExtensionBridge.ApprovalClaim,
        token: UUID
    ) -> Bool {
        guard case .claiming = lifecycle, isCurrent(token) else { return false }
        lifecycle = .working(ApprovalContext(claim: claim))
        return true
    }

    func beginAuthentication(
        claim: ExtensionBridge.ApprovalClaim,
        token: UUID
    ) -> Bool {
        guard case .working(let context) = lifecycle,
              isCurrent(token), context.claim == claim else {
            return false
        }
        lifecycle = .authenticating(context)
        return true
    }

    func finishAuthentication(
        claim: ExtensionBridge.ApprovalClaim,
        token: UUID
    ) -> Bool {
        guard case .authenticating(let context) = lifecycle,
              isCurrent(token), context.claim == claim else {
            return false
        }
        lifecycle = .working(context)
        return true
    }

    func returnToReview(token: UUID) -> Bool {
        guard isCurrent(token) else { return false }
        lifecycle = .review(feedback: errorText)
        return true
    }

    func fail(_ message: String, token: UUID? = nil) {
        guard token.map(isCurrent) ?? true else { return }
        lifecycle = .error(message: message)
    }

    func retry() {
        lifecycle = .review(feedback: nil)
        reviewToken = UUID()
    }

    func rotateReviewToken() {
        presentationRevision &+= 1
        guard state == .review else { return }
        reviewToken = UUID()
    }

    func requireRematerializationAfterAuthentication() {
        updateApprovalContext { $0.reviewRecovery = .rematerialize }
    }

    func takeAuthenticationRematerializationRequirement() -> Bool {
        var rematerialize = false
        updateApprovalContext { context in
            rematerialize = context.reviewRecovery == .rematerialize
            context.reviewRecovery = .reuse
        }
        return rematerialize
    }

    private func updateApprovalContext(
        _ update: (inout ApprovalContext) -> Void
    ) {
        switch lifecycle {
        case .working(var context):
            update(&context)
            lifecycle = .working(context)
        case .authenticating(var context):
            update(&context)
            lifecycle = .authenticating(context)
        case .review, .claiming, .persistingImmediateResponse, .error:
            break
        }
    }

}

@MainActor
final class PopupRequestSessions {

    private struct MutableSessionContext {
        let snapshot: ExtensionBridge.Snapshot
        let session: PopupRequestSession
    }

    private struct ClaimedApproval {
        let claim: ExtensionBridge.ApprovalClaim
        let token: UUID
    }

    private enum ActiveSessionResult {
        case available(PopupRequestSession)
        case absent
        case unavailable
        case secureSetupRequired
    }

    private enum TransactionApprovalDecision {
        case refused
        case alert
        case transaction(Transaction, RequestScopedWalletAccess)
    }

    private final class TransactionApprovalResolution {
        let token: UUID
        private var continuation: CheckedContinuation<TransactionApprovalDecision, Never>?
        private(set) var isAuthenticating = false
        private var walletAccess: RequestScopedWalletAccess?

        init(
            token: UUID,
            continuation: CheckedContinuation<TransactionApprovalDecision, Never>
        ) {
            self.token = token
            self.continuation = continuation
        }

        func beginAuthentication() -> Bool {
            guard continuation != nil, !isAuthenticating else { return false }
            isAuthenticating = true
            return true
        }

        func finishAuthentication() {
            isAuthenticating = false
        }

        func install(walletAccess: RequestScopedWalletAccess) {
            self.walletAccess?.invalidate()
            self.walletAccess = walletAccess
        }

        func takeWalletAccess() -> RequestScopedWalletAccess? {
            defer { walletAccess = nil }
            return walletAccess
        }

        func finish(with decision: TransactionApprovalDecision) {
            guard let continuation else { return }
            self.continuation = nil
            if case .transaction = decision {
            } else {
                walletAccess?.invalidate()
                walletAccess = nil
            }
            continuation.resume(returning: decision)
        }

        deinit {
            walletAccess?.invalidate()
        }
    }

#if os(iOS) || os(visionOS)
    static let shared = PopupRequestSessions(
        store: ExtensionBridge.shared,
        requestProcessor: ProductionPopupRequestProcessor(),
        walletEnvironment: VaultPopupWalletEnvironment(
            catalogAccess: { SafariApprovalVault.shared.catalogAccess() },
            unlockWalletAccess: {
                await SafariApprovalVault.shared.unlockResult(reason: $0)
            }
        ),
        loadsTransactionContext: true
    )
#else
    static let shared = PopupRequestSessions(
        store: ExtensionBridge.shared,
        requestProcessor: ProductionPopupRequestProcessor(),
        walletEnvironment: SourcePopupWalletEnvironment(),
        loadsTransactionContext: true
    )
#endif

    private let store: PopupRequestStore
    private let requestProcessor: PopupRequestProcessing
    private let walletEnvironment: PopupWalletEnvironment
    private let transactionApprovalOperations: TransactionApprovalOperations
    private let loadsTransactionContext: Bool
    private let invalidateNetworkCache: () -> Void
    private let selectionNetworkResolver: (String) -> EthereumNetwork?
    private let clock: () -> Date
    private let durableApprovalExecutor: DurableApprovalExecutor
    private let presenter: PopupApprovalStatePresenter
    private var sessions = [ExtensionBridge.Handle: PopupRequestSession]()
    private var transactionApprovalResolutions = [
        ExtensionBridge.Handle: TransactionApprovalResolution
    ]()

    init(
        store: PopupRequestStore,
        requestProcessor: PopupRequestProcessing,
        walletEnvironment: PopupWalletEnvironment,
        loadsTransactionContext: Bool,
        transactionApprovalOperations: TransactionApprovalOperations = .live(),
        invalidateNetworkCache: @escaping () -> Void = {
            CustomNetworkCache.shared.invalidate()
        },
        selectionNetworkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.walletEnvironment = walletEnvironment
        self.transactionApprovalOperations = transactionApprovalOperations
        self.loadsTransactionContext = loadsTransactionContext
        self.invalidateNetworkCache = invalidateNetworkCache
        self.selectionNetworkResolver = selectionNetworkResolver
        self.clock = clock
        durableApprovalExecutor = DurableApprovalExecutor(
            store: store,
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock
        )
        presenter = PopupApprovalStatePresenter()
    }

    static func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> [String: Any] {
        guard case .popup(let command) = request.command else {
            return shared.ignoredResponse()
        }
        return await shared.dispatch(
            command,
            request: request,
            profileIdentifier: profileIdentifier
        )
    }

    static func dispatchPrivateBrowsing(
        request: InternalSafariRequest
    ) async -> [String: Any] {
        return shared.privateBrowsingResponse(for: request)
    }

    func privateBrowsingResponse(
        for request: InternalSafariRequest
    ) -> [String: Any] {
        guard case .popup(let command) = request.command else {
            return ignoredResponse()
        }
        switch command {
        case .getPendingRequests:
            return presenter.pendingResponse()
        case .getApprovalState:
            return presenter.missingState(id: request.id)
        case .approveRequest, .rejectRequest, .setTransactionSpeed,
             .applyTransactionEdits, .resolveApprovalAlert:
            return ignoredResponse()
        }
    }

    nonisolated static func materializeAfterAdmission(
        handle: ExtensionBridge.Handle,
        materializesWalletDependentRequests: Bool
    ) async -> DappAdmissionDisposition {
        return await shared.materializeAfterAdmission(
            handle: handle,
            materializesWalletDependentRequests:
                materializesWalletDependentRequests
        )
    }

    func materializeAfterAdmission(
        handle: ExtensionBridge.Handle,
        materializesWalletDependentRequests: Bool = true
    ) async -> DappAdmissionDisposition {
        let snapshot: ExtensionBridge.Snapshot
        switch await store.load(handle: handle) {
        case .found(let found):
            snapshot = found
        case .missing, .unavailable:
            return .unavailable
        }
        switch snapshot.phase {
        case .responded:
            return .responseReady
        case .approving:
            return .approvalRequired
        case .queued:
            if snapshot.nativeDecisionStaged ||
                snapshot.nativeDeliveryReceipt != nil {
                return .approvalRequired
            }
        }
        guard let request = snapshot.request else { return .unavailable }
        let preparation: DappRequestPreparation
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else if !materializesWalletDependentRequests {
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
            )
        } else {
            guard let walletAccess = walletEnvironment.prepareForNewSession() else {
                if walletEnvironment.reviewPolicy == .versionedCatalog {
                    return await currentAdmissionDisposition(
                        handle: handle,
                        queued: .approvalRequired
                    )
                }
                return .unavailable
            }
            preparation = requestProcessor.prepare(
                request,
                walletAccess: walletAccess
            )
        }
        switch preparation {
        case .approval:
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
            )
        case .response(let response):
            switch await store.complete(handle: handle, response: response) {
            case .persisted:
                return .responseReady
            case .ownershipLost:
                return await currentAdmissionDisposition(
                    handle: handle,
                    queued: .unavailable
                )
            case .retryablePersistenceFailure:
                return .unavailable
            }
        }
    }

    private func currentAdmissionDisposition(
        handle: ExtensionBridge.Handle,
        queued: DappAdmissionDisposition
    ) async -> DappAdmissionDisposition {
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            switch snapshot.phase {
            case .queued:
                return snapshot.nativeDecisionStaged ||
                    snapshot.nativeDeliveryReceipt != nil
                    ? .approvalRequired
                    : queued
            case .approving:
                return .approvalRequired
            case .responded:
                return .responseReady
            }
        case .missing, .unavailable:
            return .unavailable
        }
    }

    func dispatch(
        _ command: InternalSafariRequest.PopupCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> [String: Any] {
        switch command {
        case .getPendingRequests:
            return await pendingRequestsResponse(profileIdentifier: profileIdentifier)
        case .getApprovalState(_, let payload):
            guard let snapshot = await snapshot(
                      for: request,
                      profileIdentifier: profileIdentifier
                  ) else { return missingState(id: request.id) }
            return await approvalState(snapshot: snapshot, responseMode: payload.mode)
        case .approveRequest(_, let payload):
            return await approve(
                request: request,
                profileIdentifier: profileIdentifier,
                payload: payload
            )
        case .rejectRequest:
            return await reject(
                request: request,
                profileIdentifier: profileIdentifier
            )
        case .setTransactionSpeed(_, let payload):
            guard payload.value.isFinite,
                  let context = await mutableSession(
                      for: request,
                      profileIdentifier: profileIdentifier
                  ) else { return ignoredResponse() }
            return await setTransactionSpeed(context: context, payload: payload)
        case .applyTransactionEdits(_, let payload):
            guard let context = await mutableSession(
                      for: request,
                      profileIdentifier: profileIdentifier
                  ) else { return ignoredResponse() }
            return await applyTransactionEdits(context: context, payload: payload)
        case .resolveApprovalAlert(_, let payload):
            guard let context = await mutableSession(
                      for: request,
                      profileIdentifier: profileIdentifier
                  ) else { return ignoredResponse() }
            return await resolveApprovalAlert(context: context, payload: payload)
        }
    }

    func dispatch(
        _ subject: InternalSafariRequest.Subject.Popup,
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> [String: Any] {
        guard case .popup(let command) = request.command,
              command.subject == subject else { return ignoredResponse() }
        return await dispatch(
            command,
            request: request,
            profileIdentifier: profileIdentifier
        )
    }

    private func handle(
        for request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.Handle? {
        guard let requestToken = request.requestToken else { return nil }
        return ExtensionBridge.Handle(
            id: request.id,
            requestToken: requestToken,
            profileIdentifier: profileIdentifier
        )
    }

    private func snapshot(
        for request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> ExtensionBridge.Snapshot? {
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier),
              case .found(let snapshot) = await store.load(handle: handle) else {
            return nil
        }
        return snapshot
    }

    private func reviewToken(for request: InternalSafariRequest) -> UUID? {
        guard case .popup(let command) = request.command else { return nil }
        return command.identity?.reviewToken
    }

    private func ignoredResponse() -> [String: Any] {
        return ["status": "ignored"]
    }

    private func missingState(id: Int) -> [String: Any] {
        return presenter.missingState(id: id)
    }

    private func stateResponse(
        id: Int,
        state: PopupRequestSession.State
    ) -> [String: Any] {
        return presenter.state(id: id, state: state)
    }

    private func refreshWalletsAndNetworks() -> Bool {
        let walletsAvailable = walletEnvironment.refreshWallets()
        invalidateNetworkCache()
        return walletsAvailable
    }

    private func pendingRequestsResponse(
        profileIdentifier: UUID?
    ) async -> [String: Any] {
        guard case .available(let availableSnapshots) = await store.list(
            profileIdentifier: profileIdentifier
        ) else {
            return ["status": "unavailable"]
        }
        let snapshots = availableSnapshots.values.sorted {
            $0.createdAt == $1.createdAt
                ? $0.sequence < $1.sequence
                : $0.createdAt < $1.createdAt
        }
        let currentHandles = Set(snapshots.map(\.handle))
        let staleHandles = sessions.compactMap { handle, session -> ExtensionBridge.Handle? in
            guard handle.profileIdentifier == profileIdentifier,
                  !currentHandles.contains(handle),
                  session.approvalClaim == nil else { return nil }
            return handle
        }
        staleHandles.forEach { sessions[$0] = nil }

        var requests = [[String: Any]]()
        var completedResponses = [[String: Any]]()
        for snapshot in snapshots {
            switch snapshot.phase {
            case .queued, .approving:
                requests.append(presenter.pendingRequest(snapshot))
            case .responded:
                sessions[snapshot.handle] = nil
                completedResponses.append(presenter.completedResponse(snapshot))
            }
        }
        return presenter.pendingResponse(
            requests: requests,
            completedResponses: completedResponses
        )
    }

    private func ensureSession(
        snapshot: ExtensionBridge.Snapshot
    ) -> ActiveSessionResult {
        guard !isNativeOwned(snapshot) else {
            discardSession(handle: snapshot.handle)
            return .absent
        }
        if let session = sessions[snapshot.handle] {
            if snapshot.phase == .approving &&
                (snapshot.request == nil || session.approvalClaim == nil) {
                return .absent
            }
            if snapshot.phase == .queued,
               session.state == .review,
               let reviewedAccess = session.walletAccess,
               walletEnvironment.reviewPolicy == .versionedCatalog {
                guard let currentAccess = walletEnvironment.currentReviewAccess() else {
                    discardSession(handle: snapshot.handle)
                    return .secureSetupRequired
                }
                if currentAccess.catalogIdentity !=
                    reviewedAccess.catalogIdentity {
                    discardSession(handle: snapshot.handle)
                    return ensureSession(snapshot: snapshot)
                }
            }
            return session.isImmediateResponsePersistence
                ? .absent
                : .available(session)
        }
        guard snapshot.phase == .queued,
              let request = snapshot.request else { return .absent }
        let preparation: DappRequestPreparation
        var preparedWalletAccess: WalletAccess?
        let isWalletIndependent: Bool
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
            isWalletIndependent = true
        } else {
            isWalletIndependent = false
            guard let walletAccess = walletEnvironment.prepareForNewSession() else {
                return walletEnvironment.reviewPolicy == .liveSource
                    ? .unavailable
                    : .secureSetupRequired
            }
            preparedWalletAccess = walletAccess
            preparation = requestProcessor.prepare(
                request,
                walletAccess: walletAccess
            )
        }
        switch preparation {
        case .response(let response):
            guard snapshot.phase == .queued else { return .unavailable }
            let session = PopupRequestSession(
                handle: snapshot.handle,
                request: request,
                purpose: .immediateResponsePersistence
            )
            sessions[snapshot.handle] = session
            Task { [weak self, weak session] in
                guard let self, let session else { return }
                switch await store.complete(handle: snapshot.handle, response: response) {
                case .persisted, .ownershipLost:
                    sessions[snapshot.handle] = nil
                case .retryablePersistenceFailure:
                    session.fail(Strings.failedToLoad)
                }
            }
            return .absent
        case .approval(let action):
            if !isWalletIndependent && preparedWalletAccess == nil {
                return walletEnvironment.reviewPolicy == .liveSource
                    ? .unavailable
                    : .secureSetupRequired
            }
            let session = PopupRequestSession(
                handle: snapshot.handle,
                request: request,
                purpose: .approval(action),
                walletAccess: preparedWalletAccess
            )
            sessions[snapshot.handle] = session
            if case .approveTransaction(let transactionAction) = action {
                setupTransaction(for: session, action: transactionAction)
            }
            return .available(session)
        }
    }

    private func activeSession(
        snapshot: ExtensionBridge.Snapshot
    ) -> ActiveSessionResult {
        guard snapshot.phase != .responded else { return .absent }
        return ensureSession(snapshot: snapshot)
    }

    private func isNativeOwned(_ snapshot: ExtensionBridge.Snapshot) -> Bool {
        snapshot.phase == .queued &&
            (snapshot.nativeDeliveryReceipt != nil ||
                snapshot.nativeDecisionStaged)
    }

    private func discardSession(handle: ExtensionBridge.Handle) {
        sessions[handle]?.transaction?.invalidate()
        sessions[handle] = nil
    }

    private func mutableSession(
        for request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> MutableSessionContext? {
        guard let handle = handle(
                  for: request,
                  profileIdentifier: profileIdentifier
              ),
              case .found(let snapshot) = await store.load(handle: handle),
              let session = sessions[snapshot.handle],
              reviewToken(for: request) == session.reviewToken,
              canMutateTransaction(snapshot: snapshot, session: session) else {
            return nil
        }
        return MutableSessionContext(snapshot: snapshot, session: session)
    }

    private func canMutateTransaction(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) -> Bool {
        return snapshot.phase == .queued &&
            snapshot.request != nil &&
            session.handle == snapshot.handle &&
            session.state == .review &&
            session.canBeginApproval
    }

    private func approvalState(
        snapshot: ExtensionBridge.Snapshot,
        responseMode: InternalSafariRequest.ApprovalStatePayload.Mode = .full
    ) async -> [String: Any] {
        let handle = snapshot.handle
        if snapshot.phase == .responded {
            sessions[handle] = nil
            return missingState(id: handle.id)
        }
        if isNativeOwned(snapshot) {
            discardSession(handle: handle)
            var state = stateResponse(id: handle.id, state: .working)
            state["host"] = snapshot.host
            return state
        }
        if responseMode == .full,
           let session = sessions[handle],
           session.state == .error,
           session.approvalClaim == nil,
           snapshot.phase == .queued,
           snapshot.request != nil {
            session.transaction?.invalidate()
            sessions[handle] = nil
        }
        let sessionWasCached = sessions[handle] != nil
        let activeSession = activeSession(snapshot: snapshot)
        guard case .available(let session) = activeSession else {
            if case .unavailable = activeSession {
                return PopupApprovalStatePresenter.compactError(
                    id: handle.id,
                    host: snapshot.host,
                    error: Strings.failedToLoad
                )
            }
            if case .secureSetupRequired = activeSession {
                return presenter.secureSetupRequiredState(
                    id: handle.id,
                    host: snapshot.host
                )
            }
            if let session = sessions[handle],
               session.isImmediateResponsePersistence {
                if session.state == .error {
                    return PopupApprovalStatePresenter.compactError(
                        id: handle.id,
                        host: snapshot.host,
                        error: session.errorText ?? Strings.failedToLoad
                    )
                }
                var state = stateResponse(id: handle.id, state: session.state)
                state["host"] = snapshot.host
                return state
            }
            if snapshot.phase == .approving {
                var state = stateResponse(id: handle.id, state: .working)
                state["host"] = snapshot.host
                return state
            }
            if case .found(let current) = await store.load(handle: handle),
               current.phase == .responded {
                sessions[handle] = nil
                return missingState(id: handle.id)
            }
            return missingState(id: handle.id)
        }
        if session.state == .error {
            return PopupApprovalStatePresenter.compactError(
                id: handle.id,
                host: snapshot.host,
                error: session.errorText ?? Strings.failedToLoad
            )
        }
        if responseMode == .poll,
           session.state != .review {
            return stateResponse(id: handle.id, state: session.state)
        }
        guard let action = session.approvalAction else {
            return stateResponse(id: handle.id, state: session.state)
        }
        if sessionWasCached,
           session.state == .review,
           isAccountSelection(action),
           !refreshSelectionSessionIfNeeded(session) {
            return PopupApprovalStatePresenter.compactError(
                id: handle.id,
                host: snapshot.host,
                error: Strings.failedToLoad
            )
        }
        let transactionMutationAllowed = canMutateTransaction(
            snapshot: snapshot,
            session: session
        )
        return presenter.approvalState(
            for: session,
            action: action,
            transactionMutationAllowed: transactionMutationAllowed
        )
    }

    private func isAccountSelection(_ action: DappRequestAction) -> Bool {
        switch action {
        case .selectAccount, .switchAccount:
            return true
        case .approveMessage, .approveTransaction, .addEthereumChain:
            return false
        }
    }

    private func refreshSelectionSessionIfNeeded(
        _ session: PopupRequestSession
    ) -> Bool {
        guard refreshWalletsAndNetworks() else { return false }
        if walletEnvironment.reviewPolicy == .versionedCatalog {
            return true
        }
        guard let refreshedAccess = walletEnvironment.currentReviewAccess() else { return false }
        if refreshedAccess.catalogIdentity == session.walletAccess?.catalogIdentity {
            return true
        }
        guard case .approval(let action) = requestProcessor.prepare(
                  session.request,
                  walletAccess: refreshedAccess
              ) else { return false }
        switch action {
        case .selectAccount(let selection):
            guard session.replaceSelectionAction(selection) else { return false }
        case .switchAccount(let selection):
            guard session.replaceSelectionAction(selection) else { return false }
        case .approveMessage, .approveTransaction, .addEthereumChain:
            return false
        }
        session.walletAccess = refreshedAccess
        session.rotateReviewToken()
        return true
    }

    private func approve(
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        payload: InternalSafariRequest.ApprovalPayload
    ) async -> [String: Any] {
        guard let snapshot = await snapshot(
                  for: request,
                  profileIdentifier: profileIdentifier
              ),
              snapshot.phase == .queued ||
                  (snapshot.phase == .approving && snapshot.request != nil),
              case .available(let session) = activeSession(snapshot: snapshot),
              reviewToken(for: request) == session.reviewToken,
              session.canBeginApproval,
              let action = session.approvalAction else {
            return ignoredResponse()
        }
        guard DurableApprovalExecutor.approvalRevisionsMatch(
            action: action,
            request: session.request,
            stored: snapshot.revisions,
            current: payload.revisions
        ) else {
            return await completeStaleApproval(
                snapshot: snapshot,
                session: session
            )
        }
        guard providerRevisionLeaseIsAdmissible(
            action: action,
            deadline: payload.executionDeadline
        ) else {
            return ignoredResponse()
        }
        switch action {
        case .selectAccount(let selectAction), .switchAccount(let selectAction):
            guard let selectedAccounts = payload.selectedAccounts else {
                return ignoredResponse()
            }
            return await approveAccountSelection(
                session: session,
                action: selectAction,
                selectedAccounts: selectedAccounts,
                chainId: payload.chainId
            ) ? ["status": "ok"] : ignoredResponse()
        case .approveMessage(let signAction):
            guard let executionDeadline = payload.executionDeadline,
                  await approveMessageSigning(
                session: session,
                action: signAction,
                cluster: payload.cluster,
                expectedRevisions: payload.revisions,
                executionDeadline: executionDeadline
            ) else { return ignoredResponse() }
        case .approveTransaction(let reviewedAction):
            guard let executionDeadline = payload.executionDeadline,
                  let transactionSession = session.transaction,
                  transactionSession.snapshot.canApprove else {
                return ignoredResponse()
            }
            guard let approval = await beginAndClaimApproval(for: session) else {
                return ignoredResponse()
            }
            switch await transactionApprovalDecision(
                for: session,
                transactionSession: transactionSession,
                approval: approval
            ) {
            case .refused, .alert:
                await releaseApproval(
                    approval.claim,
                    for: session,
                    token: approval.token,
                    rematerializeOnSuccess:
                        session.takeAuthenticationRematerializationRequirement()
                )
            case .transaction(let transaction, let walletAccess):
                guard case .approveTransaction(let freshAction) =
                        await refreshedSigningAction(
                            for: session,
                            reviewedAction: action,
                            approval: approval,
                            walletAccess: walletAccess,
                            expectedRevisions: payload.revisions,
                            executionDeadline: executionDeadline
                        ) else {
                    walletAccess.invalidate()
                    return ["status": "ok"]
                }
                guard let execution = NativeApprovalDecision
                        .TransactionExecution(
                            transaction,
                            reviewedNetwork: reviewedAction.resolvedNetwork
                        ),
                      let refreshedTransaction = execution.applying(
                          to: freshAction
                      ),
                      refreshedTransaction.isReadyForApproval(
                          on: freshAction.chain
                      ) else {
                    await releaseApproval(
                        approval.claim,
                        for: session,
                        token: approval.token,
                        rematerializeOnSuccess: true
                    )
                    walletAccess.invalidate()
                    return ["status": "ok"]
                }
                await beginSigningExecution(
                    claim: approval.claim,
                    for: session,
                    token: approval.token,
                    deadline: executionDeadline,
                    acquireWalletLease: {
                        walletAccess.takeExecutionLease()
                    }
                ) {
                    await freshAction.resolve(
                        refreshedTransaction
                    )
                }
                walletAccess.invalidate()
            }
        case .addEthereumChain(let addAction):
            guard let approval = await beginAndClaimApproval(for: session) else {
                return ignoredResponse()
            }
            await beginExecution(
                claim: approval.claim,
                for: session,
                token: approval.token
            ) {
                .response(await addAction.resolve(true))
            }
        }
        return ["status": "ok"]
    }

    private func completeStaleApproval(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) async -> [String: Any] {
        guard snapshot.phase == .queued else { return ignoredResponse() }
        session.transaction?.invalidate()
        let response = ResponseToExtension(
            for: session.request,
            payload: .error(ProviderResponseError(
                message: Strings.providerNotReady,
                code: 4100
            ))
        )
        switch await store.complete(handle: snapshot.handle, response: response) {
        case .persisted:
            sessions[snapshot.handle] = nil
            return ["status": "ok"]
        case .ownershipLost:
            sessions[snapshot.handle] = nil
            return ignoredResponse()
        case .retryablePersistenceFailure:
            session.fail(Strings.failedToLoad)
            return ["status": "unavailable"]
        }
    }

    private func approveAccountSelection(
        session: PopupRequestSession,
        action: SelectAccountAction,
        selectedAccounts: [InternalSafariRequest.SelectedAccount],
        chainId: String?
    ) async -> Bool {
        guard let reviewedWalletAccess = session.walletAccess else {
            return false
        }
        if let chainId,
           selectionNetworkResolver(chainId) == nil {
            return false
        }
        guard let resolved = resolvedSelectionAccounts(
            selectedAccounts,
            requiredCoin: action.coinType,
            walletAccess: reviewedWalletAccess
        ) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        let selectedChainId = chainId ?? action.network?.chainIdHexString
        let network = selectedChainId.flatMap(selectionNetworkResolver)
        let updatedAction = selectionAction(
            action,
            selectedAccounts: resolved,
            network: network
        )
        guard session.replaceSelectionAction(updatedAction) else { return false }
        if resolved.isEmpty && updatedAction.initiallyConnectedProviders.isEmpty {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        if !resolved.isEmpty,
           !updatedAction.canSubmitSelection(network: network) {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        guard refreshWalletsAndNetworks() else {
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        let refreshedWalletAccess: WalletAccess
        if walletEnvironment.reviewPolicy == .versionedCatalog {
            guard let value = walletEnvironment.currentReviewAccess(),
                  value.catalogIdentity == reviewedWalletAccess.catalogIdentity else {
                await releaseApproval(
                    approval.claim,
                    for: session,
                    token: approval.token,
                    rematerializeOnSuccess: true
                )
                return true
            }
            refreshedWalletAccess = value
        } else {
            guard let value = walletEnvironment.currentReviewAccess() else {
                await releaseApproval(approval.claim, for: session, token: approval.token)
                return true
            }
            refreshedWalletAccess = value
        }
        let refreshedNetwork = selectedChainId.flatMap(selectionNetworkResolver)
        guard let refreshedAccounts = resolvedSelectionAccounts(
            selectedAccounts,
            requiredCoin: action.coinType,
            walletAccess: refreshedWalletAccess
        ) else {
            _ = session.replaceSelectionAction(
                selectionAction(
                    action,
                    selectedAccounts: [],
                    network: refreshedNetwork
                )
            )
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        let refreshedAction = selectionAction(
            action,
            selectedAccounts: refreshedAccounts,
            network: refreshedNetwork
        )
        guard session.replaceSelectionAction(refreshedAction),
              (refreshedAccounts.isEmpty || selectedChainId == nil ||
                  refreshedNetwork != nil),
              (refreshedAccounts.isEmpty ||
                  refreshedAction.canSubmitSelection(network: refreshedNetwork)) else {
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        await beginExecution(
            claim: approval.claim,
            for: session,
            token: approval.token
        ) {
            .response(await refreshedAction.resolve(
                refreshedNetwork,
                refreshedAccounts
            ))
        }
        return true
    }

    private func resolvedSelectionAccounts(
        _ selectedAccounts: [InternalSafariRequest.SelectedAccount],
        requiredCoin: WalletCoin?,
        walletAccess: WalletAccess
    ) -> [SpecificWalletAccount]? {
        var resolved = [SpecificWalletAccount]()
        var selectedCoins = Set<WalletCoin>()
        resolved.reserveCapacity(selectedAccounts.count)
        for item in selectedAccounts {
            guard let coin = WalletCoin.correspondingToInpageProvider(item.coin),
                  requiredCoin == nil || coin == requiredCoin else { return nil }
            let account = walletEnvironment.resolveSelectedAccount(
                item,
                reviewedAccess: walletAccess
            )
            guard let account,
                  account.walletId == item.walletId,
                  account.account.coin == coin,
                  coin.normalizedAddress(account.account.address) ==
                    coin.normalizedAddress(item.address),
                  account.account.derivationPath == item.derivationPath,
                  selectedCoins.insert(coin).inserted else { return nil }
            resolved.append(account)
        }
        return resolved
    }

    private func selectionAction(
        _ action: SelectAccountAction,
        selectedAccounts: [SpecificWalletAccount],
        network: EthereumNetwork?
    ) -> SelectAccountAction {
        return SelectAccountAction(
            coinType: action.coinType,
            selectedAccounts: Set(selectedAccounts),
            initiallyConnectedProviders: action.initiallyConnectedProviders,
            network: network,
            resolve: action.resolve
        )
    }

    private func approveMessageSigning(
        session: PopupRequestSession,
        action: SignMessageAction,
        cluster: Solana.Cluster?,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> Bool {
        guard (action.solanaClusterSelection != nil) == (cluster != nil) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        guard session.beginAuthentication(
            claim: approval.claim,
            token: approval.token
        ) else {
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        guard let walletAccess = await authenticate(
            session: session,
            reason: action.subject.title
        ) else {
            _ = session.finishAuthentication(
                claim: approval.claim,
                token: approval.token
            )
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token,
                rematerializeOnSuccess:
                    session.takeAuthenticationRematerializationRequirement()
            )
            return true
        }
        guard isCurrent(session, token: approval.token),
              session.finishAuthentication(
                  claim: approval.claim,
                  token: approval.token
        ) else {
            walletAccess.invalidate()
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        guard case .approveMessage(let freshAction) =
                await refreshedSigningAction(
                    for: session,
                    reviewedAction: .approveMessage(action),
                    approval: approval,
                    walletAccess: walletAccess,
                    expectedRevisions: expectedRevisions,
                    executionDeadline: executionDeadline
                ) else {
            walletAccess.invalidate()
            return true
        }
        freshAction.solanaClusterSelection?.selectedCluster = cluster
        await beginSigningExecution(
            claim: approval.claim,
            for: session,
            token: approval.token,
            deadline: executionDeadline,
            acquireWalletLease: {
                walletAccess.takeExecutionLease()
            }
        ) {
            await freshAction.resolve(true)
        }
        walletAccess.invalidate()
        return true
    }

    private func providerRevisionLeaseIsAdmissible(
        action: DappRequestAction,
        deadline: Date?
    ) -> Bool {
        switch action {
        case .approveMessage, .approveTransaction:
            guard let deadline else { return false }
            let remaining = deadline.timeIntervalSince(clock())
            return remaining > 0 && remaining <= 180
        case .selectAccount, .switchAccount, .addEthereumChain:
            return true
        }
    }

    private func providerRevisionLeaseIsCurrent(
        for session: PopupRequestSession,
        action: DappRequestAction,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> Bool {
        guard providerRevisionLeaseIsAdmissible(
                  action: action,
                  deadline: executionDeadline
              ),
              case .found(let snapshot) = await store.load(
                  handle: session.handle
              ),
              snapshot.phase == .approving,
              snapshot.request != nil else {
            return false
        }
        return DurableApprovalExecutor.approvalRevisionsMatch(
            action: action,
            request: session.request,
            stored: snapshot.revisions,
            current: expectedRevisions
        )
    }

    private func refreshedSigningAction(
        for session: PopupRequestSession,
        reviewedAction: DappRequestAction,
        approval: ClaimedApproval,
        walletAccess: WalletAccess,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> DappRequestAction? {
        guard await providerRevisionLeaseIsCurrent(
                  for: session,
                  action: reviewedAction,
                  expectedRevisions: expectedRevisions,
                  executionDeadline: executionDeadline
              ),
              refreshWalletsAndNetworks(),
              session.walletAccess?.catalogIdentity ==
                walletAccess.catalogIdentity,
              case .approval(let freshAction) = requestProcessor.prepare(
                  session.request,
                  walletAccess: walletAccess
              ),
              signingActionsMatch(reviewedAction, freshAction) else {
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token,
                rematerializeOnSuccess: true
            )
            return nil
        }
        return freshAction
    }

    private func signingActionsMatch(
        _ reviewedAction: DappRequestAction,
        _ freshAction: DappRequestAction
    ) -> Bool {
        switch (reviewedAction, freshAction) {
        case (.approveMessage(let reviewed), .approveMessage(let fresh)):
            return reviewed.walletId == fresh.walletId &&
                Self.sameAccountIdentity(reviewed.account, fresh.account) &&
                reviewed.meta == fresh.meta &&
                (reviewed.solanaClusterSelection != nil) ==
                    (fresh.solanaClusterSelection != nil) &&
                reviewed.solanaClusterSelection?.suggestedCluster ==
                    fresh.solanaClusterSelection?.suggestedCluster
        case (.approveTransaction(let reviewed), .approveTransaction(let fresh)):
            return reviewed.walletId == fresh.walletId &&
                Self.sameAccountIdentity(reviewed.account, fresh.account) &&
                reviewed.transaction.from == fresh.transaction.from &&
                reviewed.transaction.to == fresh.transaction.to &&
                reviewed.transaction.value == fresh.transaction.value &&
                reviewed.transaction.data == fresh.transaction.data &&
                reviewed.transaction.accessList == fresh.transaction.accessList
        default:
            return false
        }
    }

    private static func sameAccountIdentity(
        _ left: WalletAccount,
        _ right: WalletAccount
    ) -> Bool {
        left.coin == right.coin &&
            left.coin.normalizedAddress(left.address) ==
                right.coin.normalizedAddress(right.address) &&
            left.derivationPath == right.derivationPath
    }

    private func beginAndClaimApproval(
        for session: PopupRequestSession
    ) async -> ClaimedApproval? {
        let presentationRevision = session.presentationRevision
        guard let token = session.beginApproval(),
              let claim = await claimApproval(
                  for: session,
                  token: token
              ) else { return nil }
        guard session.presentationRevision == presentationRevision else {
            await releaseApproval(claim, for: session, token: token)
            return nil
        }
        return ClaimedApproval(claim: claim, token: token)
    }

    private func claimApproval(
        for session: PopupRequestSession,
        token: UUID
    ) async -> ExtensionBridge.ApprovalClaim? {
        let result = await store.claim(handle: session.handle)
        switch result {
        case .claimed(let claim):
            guard isCurrent(session, token: token),
                  session.acceptClaim(claim, token: token) else {
                _ = await store.release(claim: claim)
                return nil
            }
            return claim
        case .executing, .responded, .missing:
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
        case .unavailable:
            if isCurrent(session, token: token) {
                session.fail(Strings.failedToLoad, token: token)
            }
        }
        return nil
    }

    private func authenticate(
        session: PopupRequestSession,
        reason: String
    ) async -> RequestScopedWalletAccess? {
        switch await walletEnvironment.unlock(for: session, reason: reason) {
        case .canceled:
            return nil
        case .unavailable:
            guard walletEnvironment.reviewPolicy == .versionedCatalog else { return nil }
            let reviewedIdentity = session.walletAccess?.catalogIdentity
            if let currentIdentity = walletEnvironment.currentReviewAccess()?.catalogIdentity {
                if currentIdentity != reviewedIdentity {
                    session.requireRematerializationAfterAuthentication()
                } else {
                    session.setFeedback(Strings.somethingWentWrong)
                }
            } else {
                session.setFeedback(Strings.secureApprovalSetupRequired)
                session.requireRematerializationAfterAuthentication()
            }
            return nil
        case .unlocked(let unlocked):
            if walletEnvironment.reviewPolicy == .versionedCatalog {
                guard let reviewedIdentity = session.walletAccess?.catalogIdentity,
                      unlocked.catalogIdentity == reviewedIdentity else {
                    unlocked.invalidate()
                    session.requireRematerializationAfterAuthentication()
                    return nil
                }
            }
            return unlocked
        }
    }

    private func reject(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> [String: Any] {
        guard let snapshot = await snapshot(
                  for: request,
                  profileIdentifier: profileIdentifier
              ), snapshot.phase == .queued,
              snapshot.request != nil else {
            return ignoredResponse()
        }
        switch await store.reject(handle: snapshot.handle) {
        case .persisted:
            sessions[snapshot.handle]?.transaction?.invalidate()
            sessions[snapshot.handle] = nil
            return ["status": "ok"]
        case .ownershipLost:
            return ignoredResponse()
        case .retryablePersistenceFailure:
            return ["status": "unavailable"]
        }
    }

    private func transactionApprovalDecision(
        for session: PopupRequestSession,
        transactionSession: PopupTransactionSession,
        approval: ClaimedApproval
    ) async -> TransactionApprovalDecision {
        return await withCheckedContinuation { continuation in
            let resolution = TransactionApprovalResolution(
                token: approval.token,
                continuation: continuation
            )
            transactionApprovalResolutions[session.handle] = resolution
            guard transactionSession.approve() else {
                finishTransactionApproval(
                    resolution,
                    for: session,
                    with: .refused
                )
                return
            }
        }
    }

    private func finishTransactionApproval(
        _ resolution: TransactionApprovalResolution,
        for session: PopupRequestSession,
        with decision: TransactionApprovalDecision
    ) {
        guard transactionApprovalResolutions[session.handle] === resolution else {
            return
        }
        transactionApprovalResolutions[session.handle] = nil
        resolution.finish(with: decision)
    }

    private func beginExecution(
        claim: ExtensionBridge.ApprovalClaim,
        for session: PopupRequestSession,
        token: UUID,
        operation: @escaping () async -> DappExecutionResult
    ) async {
        guard isCurrent(session, token: token) else {
            await releaseApproval(claim, for: session, token: token)
            return
        }
        let result = await durableApprovalExecutor.executeOrdinary(
            claim: claim,
            operation: operation
        )
        await finishExecution(
            result,
            claim: claim,
            for: session,
            token: token
        )
    }

    private func beginSigningExecution(
        claim: ExtensionBridge.ApprovalClaim,
        for session: PopupRequestSession,
        token: UUID,
        deadline: Date,
        acquireWalletLease: @escaping () async -> WalletExecutionLease?,
        operation: @escaping () async -> DappExecutionResult
    ) async {
        guard isCurrent(session, token: token) else {
            await releaseApproval(claim, for: session, token: token)
            return
        }
        let result = await durableApprovalExecutor.executeSigning(
            claim: claim,
            deadline: deadline,
            acquireWalletLease: acquireWalletLease,
            operation: operation
        )
        await finishExecution(
            result,
            claim: claim,
            for: session,
            token: token
        )
    }

    private func finishExecution(
        _ result: DurableApprovalExecutor.Result,
        claim: ExtensionBridge.ApprovalClaim,
        for session: PopupRequestSession,
        token: UUID
    ) async {
        switch result {
        case .persisted, .ownershipLost:
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
        case .beginRetryablePersistenceFailure:
            await releaseApproval(
                claim,
                for: session,
                token: token,
                rematerializeOnSuccess: true
            )
        case .retryablePersistenceFailure:
            if isCurrent(session, token: token) {
                session.fail(Strings.failedToLoad, token: token)
            }
        case .rolledBack:
            session.transaction?.invalidate()
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
        }
    }

    private func releaseApproval(
        _ claim: ExtensionBridge.ApprovalClaim,
        for session: PopupRequestSession,
        token: UUID,
        rematerializeOnSuccess: Bool = false
    ) async {
        switch await store.release(claim: claim) {
        case .persisted:
            if isCurrent(session, token: token) {
                if rematerializeOnSuccess {
                    session.transaction?.invalidate()
                    sessions[session.handle] = nil
                } else {
                    _ = session.returnToReview(token: token)
                }
            }
        case .ownershipLost:
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
        case .retryablePersistenceFailure:
            if isCurrent(session, token: token) {
                session.fail(Strings.failedToLoad, token: token)
            }
        }
    }

    private func isCurrent(
        _ session: PopupRequestSession,
        token: UUID
    ) -> Bool {
        return sessions[session.handle] === session &&
            session.isCurrent(token)
    }

    private func setupTransaction(
        for session: PopupRequestSession,
        action: SendTransactionAction
    ) {
        let transactionSession = PopupTransactionSession(
            action: action,
            operations: transactionApprovalOperations
        )
        transactionSession.onOutput = { [weak self, weak session] output in
            guard let self,
                  let session,
                  sessions[session.handle] === session else { return }
            handleTransactionOutput(output, session: session)
        }
        session.transaction = transactionSession
        transactionSession.start()
        guard loadsTransactionContext else { return }
        PriceService.shared.update()
        Ethereum.shared.getBalance(
            network: action.chain,
            address: action.account.address
        ) { [weak transactionSession] balance in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    transactionSession?.balance =
                        balance.eth(shortest: true) + " " + action.chain.symbol
                }
            }
        }
    }

    private func handleTransactionOutput(
        _ output: TransactionApprovalOutput,
        session: PopupRequestSession
    ) {
        guard let transactionSession = session.transaction else { return }
        switch output {
        case .snapshot, .verifiedFeeEstimate, .editorRequest:
            session.rotateReviewToken()
        case .authenticationRequest(let token):
            guard let resolution = transactionApprovalResolutions[session.handle],
                  resolution.token == session.reviewToken,
                  let claim = session.approvalClaim,
                  resolution.beginAuthentication(),
                  session.beginAuthentication(
                      claim: claim,
                      token: resolution.token
                  ) else {
                if let resolution = transactionApprovalResolutions[session.handle] {
                    finishTransactionApproval(
                        resolution,
                        for: session,
                        with: .refused
                    )
                }
                return
            }
            Task { @MainActor in
                let walletAccess = await authenticate(
                    session: session,
                    reason: Strings.sendTransaction
                )
                guard transactionApprovalResolutions[session.handle] === resolution else {
                    return
                }
                resolution.finishAuthentication()
                let authenticationFinished = isCurrent(
                    session,
                    token: resolution.token
                ) && session.finishAuthentication(
                    claim: claim,
                    token: resolution.token
                )
                if authenticationFinished, let walletAccess {
                    resolution.install(walletAccess: walletAccess)
                } else {
                    walletAccess?.invalidate()
                }
                transactionSession.authenticationCompleted(
                    token: token,
                    succeeded: walletAccess != nil && authenticationFinished
                )
                if walletAccess == nil || !authenticationFinished {
                    finishTransactionApproval(
                        resolution,
                        for: session,
                        with: .refused
                    )
                }
            }
        case .alert:
            if let resolution = transactionApprovalResolutions[session.handle] {
                finishTransactionApproval(
                    resolution,
                    for: session,
                    with: .alert
                )
            } else {
                session.rotateReviewToken()
            }
        case .completion(let transaction):
            guard let resolution = transactionApprovalResolutions[session.handle] else {
                return
            }
            let decision: TransactionApprovalDecision
            if let transaction,
               let walletAccess = resolution.takeWalletAccess() {
                decision = .transaction(transaction, walletAccess)
            } else {
                decision = .refused
            }
            finishTransactionApproval(
                resolution,
                for: session,
                with: decision
            )
        }
    }

    private func setTransactionSpeed(
        context: MutableSessionContext,
        payload: InternalSafariRequest.TransactionSpeedPayload
    ) async -> [String: Any] {
        let snapshot = context.snapshot
        let session = context.session
        guard let transactionSession = session.transaction else {
            return ignoredResponse()
        }
        transactionSession.setSpeed(payload)
        return await approvalState(snapshot: snapshot)
    }

    private func applyTransactionEdits(
        context: MutableSessionContext,
        payload: InternalSafariRequest.TransactionEditsPayload
    ) async -> [String: Any] {
        let snapshot = context.snapshot
        let session = context.session
        guard let transactionSession = session.transaction,
              case .approveTransaction(let action) = session.approvalAction else {
            return ignoredResponse()
        }
        guard transactionSession.applyEdits(payload, chain: action.chain) else {
            var state = await approvalState(snapshot: snapshot)
            state["editsError"] = true
            return state
        }
        return await approvalState(snapshot: snapshot)
    }

    private func resolveApprovalAlert(
        context: MutableSessionContext,
        payload: InternalSafariRequest.ApprovalAlertPayload
    ) async -> [String: Any] {
        let snapshot = context.snapshot
        let session = context.session
        guard let transactionSession = session.transaction,
              transactionSession.resolveAlert(
                  action: payload.action
              ) else {
            return ignoredResponse()
        }
        return await approvalState(snapshot: snapshot)
    }


}
