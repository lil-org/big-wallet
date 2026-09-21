// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupRequestSession {

    enum State: String {
        case review, authenticating, working, error
    }

    private enum Lifecycle {
        case review(feedback: String?)
        case claiming
        case working(ApprovalContext)
        case authenticating(ApprovalContext)
        case error(message: String)
    }

    private struct ApprovalContext {
        let claim: ExtensionBridge.ApprovalClaim
        var feedback: String?
    }

    let handle: ExtensionBridge.Handle
    let request: SafariRequest
    var walletAccess: WalletAccess?
    private(set) var approvalAction: DappRequestAction
    var transaction: PopupTransactionSession?
    private var lifecycle: Lifecycle
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0

    init(
        handle: ExtensionBridge.Handle,
        request: SafariRequest,
        action: DappRequestAction,
        walletAccess: WalletAccess? = nil
    ) {
        self.handle = handle
        self.request = request
        self.approvalAction = action
        self.walletAccess = walletAccess
        lifecycle = .review(feedback: nil)
    }

    var state: State {
        switch lifecycle {
        case .review:
            return .review
        case .claiming, .working:
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
        case .review, .claiming, .error:
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
        case .claiming:
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
        case .claiming:
            break
        }
    }

    func replaceSelectionAction(_ action: SelectAccountAction) -> Bool {
        switch approvalAction {
        case .selectAccount:
            approvalAction = .selectAccount(action)
            return true
        case .switchAccount:
            approvalAction = .switchAccount(action)
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

    func rotateReviewToken() {
        presentationRevision &+= 1
        guard state == .review else { return }
        reviewToken = UUID()
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
        case .review, .claiming, .error:
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

    private enum MutableSessionResult {
        case available(MutableSessionContext)
        case ignored
        case unavailable
    }

    private struct ClaimedApproval {
        let claim: ExtensionBridge.ApprovalClaim
        let token: UUID
    }

    private enum AuthenticationOutcome {
        case unlocked(RequestScopedWalletAccess)
        case cancelled
        case unavailable(feedback: String)
        case reviewChanged
        case superseded
    }

    private enum SigningValidation {
        case valid
        case reviewChanged
        case superseded
    }

    private enum ActiveSessionResult {
        case available(PopupRequestSession)
        case immediateResponse(ImmediateResponsePersistence.State)
        case absent
        case secureSetupRequired
    }

    private final class ImmediateResponsePersistence {
        enum State {
            case working, failed
        }

        var state: State = .working
    }

#if os(iOS) || os(visionOS)
    static let shared = PopupRequestSessions(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor(),
        walletEnvironment: PopupWalletEnvironment(
            catalogAccess: { SafariApprovalVault.shared.catalogAccess() },
            unlockWalletAccess: {
                await SafariApprovalVault.shared.unlockResult(reason: $0)
            }
        ),
        loadsTransactionContext: true
    )
#endif

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let walletEnvironment: PopupWalletEnvironment
    private let transactionApprovalOperations: TransactionApprovalOperations
    private let loadsTransactionContext: Bool
    private let invalidateNetworkCache: () -> Void
    private let selectionNetworkResolver: (String) -> EthereumNetwork?
    private let signingNetworkResolver: (Int) -> ResolvedEthereumNetwork?
    private let clock: () -> Date
    private let durableApprovalExecutor: DurableApprovalExecutor
    private let presenter: PopupApprovalStatePresenter
    private var sessions = [ExtensionBridge.Handle: PopupRequestSession]()
    private var immediateResponses = [ExtensionBridge.Handle: ImmediateResponsePersistence]()

    init(
        store: PopupRequestStore,
        requestProcessor: DappRequestProcessing,
        walletEnvironment: PopupWalletEnvironment,
        loadsTransactionContext: Bool,
        transactionApprovalOperations: TransactionApprovalOperations = .live(),
        invalidateNetworkCache: @escaping () -> Void = {
            CustomNetworkCache.shared.invalidate()
        },
        selectionNetworkResolver: @escaping (String) -> EthereumNetwork? = {
            Networks.withChainIdHex($0)
        },
        signingNetworkResolver: @escaping (Int) -> ResolvedEthereumNetwork? = {
            guard case .resolved(let network) = Nodes.resolution(chainId: $0) else { return nil }
            return network
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
        self.signingNetworkResolver = signingNetworkResolver
        self.clock = clock
        durableApprovalExecutor = DurableApprovalExecutor(
            store: store,
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock
        )
        presenter = PopupApprovalStatePresenter()
    }

#if os(iOS) || os(visionOS)
    static func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        return await shared.dispatch(
            request: request,
            profileIdentifier: profileIdentifier
        )
    }

    static func dispatchPrivateBrowsing(
        request: InternalSafariRequest
    ) async -> PopupResponse {
        return shared.privateBrowsingResponse(for: request)
    }

#endif

    func privateBrowsingResponse(
        for request: InternalSafariRequest
    ) -> PopupResponse {
        guard case .popup(let command) = request.command else {
            return ignoredResponse()
        }
        switch command {
        case .getPendingRequests:
            return presenter.pendingResponse()
        case .getApprovalState, .retryApproval, .approveRequest, .rejectRequest, .setTransactionSpeed,
             .applyTransactionEdits, .resolveApprovalAlert:
            return ignoredResponse()
        }
    }

    func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        let response = await dispatchCommand(request: request, profileIdentifier: profileIdentifier)
        guard case .popup(let command) = request.command,
              case .status(let status) = response else { return response }
        if case .getPendingRequests = command { return response }
        if status == .unavailable { return response }
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
            return ignoredResponse()
        }
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            let current = await approvalState(snapshot: snapshot)
            guard let approval = current.approvalState else { return .status(.unavailable) }
            return .command(status, approval)
        case .missing:
            return .command(status, presenter.missingState(id: request.id).approvalState)
        case .unavailable:
            return .status(.unavailable)
        }
    }

    private func dispatchCommand(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        guard case .popup(let command) = request.command else {
            return ignoredResponse()
        }
        switch command {
        case .getPendingRequests:
            return await pendingRequestsResponse(profileIdentifier: profileIdentifier)
        case .getApprovalState, .retryApproval:
            guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
                return ignoredResponse()
            }
            let snapshot: ExtensionBridge.Snapshot
            switch await store.load(handle: handle) {
            case .found(let value): snapshot = value
            case .missing: return missingState(id: request.id)
            case .unavailable: return .status(.unavailable)
            }
            if case .retryApproval = command,
               case .queued(_, .unowned) = snapshot.state {
                if sessions[snapshot.handle]?.state == .error {
                    discardSession(handle: snapshot.handle)
                }
                if immediateResponses[snapshot.handle]?.state == .failed {
                    immediateResponses[snapshot.handle] = nil
                }
            }
            return await approvalState(snapshot: snapshot)
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
            guard payload.value.isFinite else { return ignoredResponse() }
            switch await mutableSession(for: request, profileIdentifier: profileIdentifier) {
            case .available(let context):
                return await setTransactionSpeed(context: context, payload: payload)
            case .ignored: return ignoredResponse()
            case .unavailable: return .status(.unavailable)
            }
        case .applyTransactionEdits(_, let payload):
            switch await mutableSession(for: request, profileIdentifier: profileIdentifier) {
            case .available(let context):
                return await applyTransactionEdits(context: context, payload: payload)
            case .ignored: return ignoredResponse()
            case .unavailable: return .status(.unavailable)
            }
        case .resolveApprovalAlert(_, let payload):
            switch await mutableSession(for: request, profileIdentifier: profileIdentifier) {
            case .available(let context):
                return await resolveApprovalAlert(context: context, payload: payload)
            case .ignored: return ignoredResponse()
            case .unavailable: return .status(.unavailable)
            }
        }
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
    ) async -> ExtensionBridge.SnapshotResult {
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
            return .missing
        }
        return await store.load(handle: handle)
    }

    private func reviewToken(for request: InternalSafariRequest) -> UUID? {
        guard case .popup(let command) = request.command else { return nil }
        return command.identity?.reviewToken
    }

    private func ignoredResponse() -> PopupResponse {
        return .status(.ignored)
    }

    private func missingState(id: Int) -> PopupResponse {
        return presenter.missingState(id: id)
    }

    private func stateResponse(
        id: Int,
        state: PopupRequestSession.State,
        host: String? = nil
    ) -> PopupResponse {
        return presenter.state(id: id, state: state, host: host)
    }

    private func refreshWalletsAndNetworks() -> WalletAccess? {
        invalidateNetworkCache()
        return walletEnvironment.currentReviewAccess()
    }

    private func pendingRequestsResponse(
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        guard case .available(let availableSnapshots) = await store.list(
            profileIdentifier: profileIdentifier
        ) else {
            return .queueUnavailable
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
        staleHandles.forEach { discardSession(handle: $0) }
        let staleImmediateResponses = immediateResponses.keys.filter {
            $0.profileIdentifier == profileIdentifier && !currentHandles.contains($0)
        }
        staleImmediateResponses.forEach { immediateResponses[$0] = nil }

        var requests = [PopupPendingRequest]()
        var completedResponses = [PopupCompletedResponse]()
        for snapshot in snapshots {
            switch snapshot.phase {
            case .queued, .approving:
                requests.append(presenter.pendingRequest(snapshot))
            case .responded:
                discardSession(handle: snapshot.handle)
                immediateResponses[snapshot.handle] = nil
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
        guard !snapshot.isQueuedForNativeApproval else {
            discardSession(handle: snapshot.handle)
            immediateResponses[snapshot.handle] = nil
            return .absent
        }
        if let session = sessions[snapshot.handle] {
            if snapshot.phase == .approving &&
                session.approvalClaim == nil {
                return .absent
            }
            if snapshot.phase == .queued,
               session.state == .review,
               let reviewedAccess = session.walletAccess {
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
            return .available(session)
        }
        guard case .queued(let request, .unowned) = snapshot.state else { return .absent }
        if let persistence = immediateResponses[snapshot.handle] {
            return .immediateResponse(persistence.state)
        }
        let preparation: DappRequestPreparation
        var preparedWalletAccess: WalletAccess?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else {
            guard let walletAccess = walletEnvironment.currentReviewAccess() else {
                return .secureSetupRequired
            }
            preparedWalletAccess = walletAccess
            preparation = requestProcessor.prepare(
                request,
                walletAccess: walletAccess
            )
        }
        switch preparation {
        case .response(let response):
            persistImmediateResponse(response, handle: snapshot.handle)
            return .immediateResponse(.working)
        case .approval(let action):
            let session = PopupRequestSession(
                handle: snapshot.handle,
                request: request,
                action: action,
                walletAccess: preparedWalletAccess
            )
            sessions[snapshot.handle] = session
            if case .approveTransaction(let transactionAction) = action {
                setupTransaction(for: session, action: transactionAction)
            }
            return .available(session)
        }
    }

    private func persistImmediateResponse(
        _ response: ResponseToExtension,
        handle: ExtensionBridge.Handle
    ) {
        let persistence = ImmediateResponsePersistence()
        immediateResponses[handle] = persistence
        Task { [weak self, store] in
            let result = await store.complete(handle: handle, response: response)
            guard let self, immediateResponses[handle] === persistence else { return }
            switch result {
            case .persisted, .ownershipLost:
                immediateResponses[handle] = nil
            case .retryablePersistenceFailure:
                persistence.state = .failed
            }
        }
    }

    private func activeSession(
        snapshot: ExtensionBridge.Snapshot
    ) -> ActiveSessionResult {
        guard snapshot.phase != .responded else { return .absent }
        return ensureSession(snapshot: snapshot)
    }

    private func discardSession(handle: ExtensionBridge.Handle) {
        let session = sessions.removeValue(forKey: handle)
        session?.transaction?.invalidate()
    }

    private func mutableSession(
        for request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> MutableSessionResult {
        let snapshot: ExtensionBridge.Snapshot
        switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
        case .found(let value): snapshot = value
        case .missing: return .ignored
        case .unavailable: return .unavailable
        }
        guard let session = sessions[snapshot.handle],
              reviewToken(for: request) == session.reviewToken,
              canMutateTransaction(snapshot: snapshot, session: session) else {
            return .ignored
        }
        return .available(MutableSessionContext(snapshot: snapshot, session: session))
    }

    private func canMutateTransaction(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) -> Bool {
        return snapshot.phase == .queued &&
            session.handle == snapshot.handle &&
            session.state == .review &&
            session.canBeginApproval
    }

    private func approvalState(
        snapshot: ExtensionBridge.Snapshot,
        editsError: Bool? = nil
    ) async -> PopupResponse {
        let handle = snapshot.handle
        if snapshot.phase == .responded {
            discardSession(handle: handle)
            immediateResponses[handle] = nil
            return missingState(id: handle.id)
        }
        if snapshot.isQueuedForNativeApproval {
            discardSession(handle: handle)
            immediateResponses[handle] = nil
            return stateResponse(id: handle.id, state: .working, host: snapshot.host)
        }
        let sessionWasCached = sessions[handle] != nil
        let activeSession = activeSession(snapshot: snapshot)
        guard case .available(let session) = activeSession else {
            if case .secureSetupRequired = activeSession {
                return presenter.secureSetupRequiredState(
                    id: handle.id,
                    host: snapshot.host
                )
            }
            if case .immediateResponse(let persistenceState) = activeSession {
                if persistenceState == .failed {
                    return PopupApprovalStatePresenter.errorState(
                        id: handle.id,
                        host: snapshot.host,
                        error: Strings.failedToLoad
                    )
                }
                return stateResponse(id: handle.id, state: .working, host: snapshot.host)
            }
            if snapshot.phase == .approving {
                return stateResponse(id: handle.id, state: .working, host: snapshot.host)
            }
            switch await store.load(handle: handle) {
            case .found(let current) where current.phase == .responded:
                discardSession(handle: handle)
                immediateResponses[handle] = nil
            case .found, .missing:
                break
            case .unavailable:
                return .status(.unavailable)
            }
            return missingState(id: handle.id)
        }
        if session.state == .error {
            return PopupApprovalStatePresenter.errorState(
                id: handle.id,
                host: snapshot.host,
                error: session.errorText ?? Strings.failedToLoad
            )
        }
        if session.state != .review {
            return stateResponse(id: handle.id, state: session.state, host: snapshot.host)
        }
        let action = session.approvalAction
        if sessionWasCached, session.state == .review {
            switch action {
            case .selectAccount, .switchAccount:
                invalidateNetworkCache()
            case .approveMessage, .approveTransaction, .addEthereumChain:
                break
            }
        }
        let transactionMutationAllowed = canMutateTransaction(
            snapshot: snapshot,
            session: session
        )
        return presenter.approvalState(
            for: session,
            action: action,
            transactionMutationAllowed: transactionMutationAllowed,
            editsError: editsError
        )
    }

    private func approve(
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        payload: InternalSafariRequest.ApprovalPayload
    ) async -> PopupResponse {
        let snapshot: ExtensionBridge.Snapshot
        switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
        case .found(let value): snapshot = value
        case .missing: return ignoredResponse()
        case .unavailable: return .status(.unavailable)
        }
        guard snapshot.phase != .responded,
              case .available(let session) = activeSession(snapshot: snapshot),
              reviewToken(for: request) == session.reviewToken,
              session.canBeginApproval else {
            return ignoredResponse()
        }
        let action = session.approvalAction
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
            ) ? .status(.ok) : ignoredResponse()
        case .approveMessage(let signAction):
            guard let executionDeadline = payload.executionDeadline,
                  await approveMessageSigning(
                session: session,
                action: signAction,
                cluster: payload.cluster,
                expectedRevisions: payload.revisions,
                executionDeadline: executionDeadline
            ) else { return ignoredResponse() }
        case .approveTransaction:
            guard let executionDeadline = payload.executionDeadline,
                  session.transaction?.snapshot.canApprove == true else {
                return ignoredResponse()
            }
            guard await runSigningApproval(
                session: session,
                action: action,
                cluster: nil,
                expectedRevisions: payload.revisions,
                executionDeadline: executionDeadline
            ) else { return ignoredResponse() }
        case .addEthereumChain:
            guard let approval = await beginAndClaimApproval(for: session) else {
                return ignoredResponse()
            }
            await beginExecution(
                claim: approval.claim,
                for: session,
                token: approval.token
            ) {
                await self.executeDecision(
                    request: session.request,
                    action: action,
                    decision: .addEthereumChain,
                    walletAccess: nil
                )
            }
        }
        return .status(.ok)
    }

    private func completeStaleApproval(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) async -> PopupResponse {
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
            discardSession(handle: snapshot.handle)
            return .status(.ok)
        case .ownershipLost:
            discardSession(handle: snapshot.handle)
            return ignoredResponse()
        case .retryablePersistenceFailure:
            session.fail(Strings.failedToLoad)
            return .status(.unavailable)
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
        let selection = DappApprovalDecision.AccountSelection(
            accounts: selectedAccounts.map {
                .init(
                    walletID: $0.walletId,
                    address: $0.address,
                    provider: $0.coin,
                    derivationPath: $0.derivationPath
                )
            },
            ethereumChainID: chainId
        )
        guard let resolved = DappApprovalValidator.resolveSelection(
            action: action,
            selection: selection,
            accounts: reviewedWalletAccess.orderedAccounts,
            networkResolver: selectionNetworkResolver
        ) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        let updatedAction = selectionAction(
            action,
            selectedAccounts: resolved.accounts,
            network: resolved.network
        )
        guard session.replaceSelectionAction(updatedAction) else { return false }
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        guard let refreshedWalletAccess = refreshWalletsAndNetworks() else {
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        guard refreshedWalletAccess.catalogIdentity == reviewedWalletAccess.catalogIdentity else {
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token,
                rematerializeOnSuccess: true
            )
            return true
        }
        guard let refreshed = DappApprovalValidator.resolveSelection(
            action: action,
            selection: selection,
            accounts: refreshedWalletAccess.orderedAccounts,
            networkResolver: selectionNetworkResolver
        ) else {
            _ = session.replaceSelectionAction(
                selectionAction(
                    action,
                    selectedAccounts: [],
                    network: (selection.ethereumChainID ?? action.network?.chainIdHexString)
                        .flatMap(selectionNetworkResolver)
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
            selectedAccounts: refreshed.accounts,
            network: refreshed.network
        )
        guard session.replaceSelectionAction(refreshedAction) else { return false }
        let approvedAction = session.approvalAction
        await beginExecution(
            claim: approval.claim,
            for: session,
            token: approval.token
        ) {
            await self.executeDecision(
                request: session.request,
                action: approvedAction,
                decision: .accountSelection(selection),
                walletAccess: refreshedWalletAccess
            )
        }
        return true
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
            network: network
        )
    }

    private func approveMessageSigning(
        session: PopupRequestSession,
        action: SignMessageAction,
        cluster: Solana.Cluster?,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> Bool {
        guard case .success = DappApprovalValidator.resolve(
            action: .approveMessage(action),
            decision: .message(.init(solanaCluster: cluster)),
            accounts: nil,
            networkResolver: selectionNetworkResolver
        ) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        return await runSigningApproval(
            session: session,
            action: .approveMessage(action),
            cluster: cluster,
            expectedRevisions: expectedRevisions,
            executionDeadline: executionDeadline
        )
    }

    private func runSigningApproval(
        session: PopupRequestSession,
        action: DappRequestAction,
        cluster: Solana.Cluster?,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> Bool {
        let reason: String
        let transactionSession: PopupTransactionSession?
        switch action {
        case .approveMessage(let message):
            reason = message.subject.title
            transactionSession = nil
        case .approveTransaction:
            reason = Strings.sendTransaction
            guard let transaction = session.transaction else { return false }
            transactionSession = transaction
        case .selectAccount, .switchAccount, .addEthereumChain:
            return false
        }
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        let transactionToken = transactionSession?.beginApproval()
        if transactionSession != nil && transactionToken == nil {
            await releaseApproval(approval.claim, for: session, token: approval.token)
            return true
        }
        let authentication = await authenticateClaimedSession(
            session: session,
            approval: approval,
            reason: reason
        )
        guard case .unlocked(let walletAccess) = authentication else {
            if let transactionSession, let transactionToken {
                _ = await transactionSession.finishAuthentication(
                    token: transactionToken,
                    succeeded: false
                )
            }
            let rematerialize: Bool
            switch authentication {
            case .cancelled:
                rematerialize = false
            case .unavailable(let feedback):
                if isCurrent(session, token: approval.token) {
                    session.setFeedback(feedback)
                }
                rematerialize = false
            case .reviewChanged, .superseded:
                rematerialize = true
            case .unlocked:
                preconditionFailure()
            }
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token,
                rematerializeOnSuccess: rematerialize
            )
            return true
        }
        defer { walletAccess.invalidate() }
        let decision: DappApprovalDecision
        if let transactionSession, let transactionToken,
           case .approveTransaction(let reviewedAction) = action {
            switch await transactionSession.finishAuthentication(
                token: transactionToken,
                succeeded: true
            ) {
            case .approved(let transaction):
                guard let execution = DappApprovalDecision.TransactionExecution(
                    transaction,
                    reviewedNetwork: reviewedAction.resolvedNetwork
                ) else {
                    await releaseApproval(
                        approval.claim, for: session, token: approval.token,
                        rematerializeOnSuccess: true
                    )
                    return true
                }
                decision = .transaction(execution)
            case .reviewRequired:
                await releaseApproval(approval.claim, for: session, token: approval.token)
                return true
            case .invalidated:
                await releaseApproval(
                    approval.claim, for: session, token: approval.token,
                    rematerializeOnSuccess: true
                )
                return true
            }
        } else {
            decision = .message(.init(solanaCluster: cluster))
        }
        guard case .valid = await validateSigningAccess(
            for: session,
            reviewedAction: action,
            approval: approval,
            walletAccess: walletAccess,
            expectedRevisions: expectedRevisions,
            executionDeadline: executionDeadline
        ) else {
            await releaseApproval(
                approval.claim, for: session, token: approval.token,
                rematerializeOnSuccess: true
            )
            return true
        }
        await beginSigningExecution(
            claim: approval.claim,
            for: session,
            token: approval.token,
            deadline: executionDeadline,
            acquireWalletLease: { await walletAccess.takeExecutionLease() }
        ) {
            await self.executeDecision(
                request: session.request,
                action: action,
                decision: decision,
                walletAccess: walletAccess
            )
        }
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
              snapshot.phase == .approving else {
            return false
        }
        return DurableApprovalExecutor.approvalRevisionsMatch(
            action: action,
            request: session.request,
            stored: snapshot.revisions,
            current: expectedRevisions
        )
    }

    private func validateSigningAccess(
        for session: PopupRequestSession,
        reviewedAction: DappRequestAction,
        approval: ClaimedApproval,
        walletAccess: WalletAccess,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> SigningValidation {
        guard isCurrent(session, token: approval.token) else { return .superseded }
        let signer: (walletID: String, account: WalletAccount)
        switch reviewedAction {
        case .approveMessage(let action):
            signer = (action.walletId, action.account)
        case .approveTransaction(let action):
            signer = (action.walletId, action.account)
        case .selectAccount, .switchAccount, .addEthereumChain:
            return .reviewChanged
        }
        let revisionIsCurrent = await providerRevisionLeaseIsCurrent(
            for: session,
            action: reviewedAction,
            expectedRevisions: expectedRevisions,
            executionDeadline: executionDeadline
        )
        let walletsAvailable = refreshWalletsAndNetworks() != nil
        let networkMatches: Bool
        if case .approveTransaction(let action) = reviewedAction {
            if let current = signingNetworkResolver(action.chain.chainId) {
                networkMatches = DappApprovalDecision.NetworkIdentity(current) ==
                    DappApprovalDecision.NetworkIdentity(action.resolvedNetwork)
            } else {
                networkMatches = false
            }
        } else {
            networkMatches = true
        }
        guard revisionIsCurrent,
              walletsAvailable,
              session.walletAccess?.catalogIdentity == walletAccess.catalogIdentity,
              walletAccess.orderedAccounts.contains(where: {
                  $0.walletId == signer.walletID &&
                      Self.sameAccountIdentity($0.account, signer.account)
              }),
              networkMatches else {
            return .reviewChanged
        }
        return isCurrent(session, token: approval.token) ? .valid : .superseded
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
                discardSession(handle: session.handle)
            }
        case .unavailable:
            if isCurrent(session, token: token) {
                session.fail(Strings.failedToLoad, token: token)
            }
        }
        return nil
    }

    private func authenticateClaimedSession(
        session: PopupRequestSession,
        approval: ClaimedApproval,
        reason: String
    ) async -> AuthenticationOutcome {
        guard session.beginAuthentication(
            claim: approval.claim,
            token: approval.token
        ) else { return .superseded }
        let outcome = await authenticate(session: session, reason: reason)
        guard isCurrent(session, token: approval.token),
              session.finishAuthentication(
                claim: approval.claim,
                token: approval.token
              ) else {
            if case .unlocked(let walletAccess) = outcome {
                walletAccess.invalidate()
            }
            return .superseded
        }
        return outcome
    }

    private func authenticate(
        session: PopupRequestSession,
        reason: String
    ) async -> AuthenticationOutcome {
        switch await walletEnvironment.unlock(reason) {
        case .canceled:
            return .cancelled
        case .unavailable:
            guard let currentIdentity = walletEnvironment.currentReviewAccess()?.catalogIdentity,
                  currentIdentity == session.walletAccess?.catalogIdentity else {
                return .reviewChanged
            }
            return .unavailable(feedback: Strings.somethingWentWrong)
        case .unlocked(let unlocked):
            guard let reviewedIdentity = session.walletAccess?.catalogIdentity,
                  unlocked.catalogIdentity == reviewedIdentity else {
                unlocked.invalidate()
                return .reviewChanged
            }
            return .unlocked(unlocked)
        }
    }

    private func reject(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        let snapshot: ExtensionBridge.Snapshot
        switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
        case .found(let value): snapshot = value
        case .missing: return ignoredResponse()
        case .unavailable: return .status(.unavailable)
        }
        guard snapshot.phase == .queued else {
            return ignoredResponse()
        }
        switch await store.reject(handle: snapshot.handle) {
        case .persisted:
            discardSession(handle: snapshot.handle)
            immediateResponses[snapshot.handle] = nil
            return .status(.ok)
        case .ownershipLost:
            return ignoredResponse()
        case .retryablePersistenceFailure:
            return .status(.unavailable)
        }
    }

    private func executeDecision(
        request: SafariRequest,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        walletAccess: WalletAccess?
    ) async -> DappExecutionResult {
        let accounts: [SpecificWalletAccount]?
        if case .accountSelection = decision {
            accounts = walletAccess?.orderedAccounts
        } else {
            accounts = nil
        }
        guard case .success(let approval) = DappApprovalValidator.resolve(
            action: action,
            decision: decision,
            accounts: accounts,
            networkResolver: selectionNetworkResolver
        ) else { return .rollback }
        return await requestProcessor.execute(
            request: request,
            approval: approval,
            walletAccess: walletAccess
        )
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
                discardSession(handle: session.handle)
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
            if sessions[session.handle] === session {
                discardSession(handle: session.handle)
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
                    discardSession(handle: session.handle)
                } else {
                    _ = session.returnToReview(token: token)
                }
            }
        case .ownershipLost:
            if sessions[session.handle] === session {
                discardSession(handle: session.handle)
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
        transactionSession.onChange = { [weak self, weak session] in
            guard let self,
                  let session,
                  sessions[session.handle] === session else { return }
            session.rotateReviewToken()
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

    private func setTransactionSpeed(
        context: MutableSessionContext,
        payload: InternalSafariRequest.TransactionSpeedPayload
    ) async -> PopupResponse {
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
    ) async -> PopupResponse {
        let snapshot = context.snapshot
        let session = context.session
        guard let transactionSession = session.transaction,
              case .approveTransaction(let action) = session.approvalAction else {
            return ignoredResponse()
        }
        guard transactionSession.applyEdits(payload, chain: action.chain) else {
            return await approvalState(snapshot: snapshot, editsError: true)
        }
        return await approvalState(snapshot: snapshot)
    }

    private func resolveApprovalAlert(
        context: MutableSessionContext,
        payload: InternalSafariRequest.ApprovalAlertPayload
    ) async -> PopupResponse {
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
