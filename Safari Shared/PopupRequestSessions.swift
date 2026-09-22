// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupRequestSession {

    enum State: String {
        case review, authenticating, working, error
    }

    struct SelectionDraft {
        let selectedAccounts: Set<SpecificWalletAccount>
        let network: EthereumNetwork?

        func applying(to action: SelectAccountAction) -> SelectAccountAction {
            SelectAccountAction(
                coinType: action.coinType,
                selectedAccounts: selectedAccounts,
                initiallyConnectedProviders: action.initiallyConnectedProviders,
                network: network
            )
        }
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
    var reviewCatalog: WalletReviewCatalog?
    let preparedAction: DappRequestAction
    var selectionDraft: SelectionDraft?
    var transaction: PopupTransactionSession?
    private var lifecycle: Lifecycle
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0

    init(
        handle: ExtensionBridge.Handle,
        request: SafariRequest,
        action: DappRequestAction,
        reviewCatalog: WalletReviewCatalog? = nil
    ) {
        self.handle = handle
        self.request = request
        self.preparedAction = action
        self.reviewCatalog = reviewCatalog
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

    var reviewAction: DappRequestAction {
        guard let selectionDraft else { return preparedAction }
        switch preparedAction {
        case .selectAccount(let action):
            return .selectAccount(selectionDraft.applying(to: action))
        case .switchAccount(let action):
            return .switchAccount(selectionDraft.applying(to: action))
        case .approveMessage, .approveTransaction, .addEthereumChain:
            return preparedAction
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

    private enum PopupCommandOutcome {
        case applied(editsError: Bool? = nil)
        case ignored
        case unavailable
    }

    private enum ApprovalStateLoad {
        case available(PopupApprovalState)
        case unavailable
    }

    private enum MutableSessionResult {
        case available(PopupRequestSession)
        case ignored
        case unavailable
    }

    private struct ClaimedApproval {
        let claim: ExtensionBridge.ApprovalClaim
        let token: UUID
    }

    private enum AuthenticationOutcome {
        case unlocked(catalog: WalletReviewCatalog, signer: RequestScopedWalletAccess)
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

    private struct SigningExecutionContext {
        let access: RequestScopedWalletAccess
        let handle: ExtensionBridge.Handle
        let deadline: Date
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
            reviewCatalog: { SafariApprovalVault.shared.reviewCatalog() },
            unlockWallets: {
                await SafariApprovalVault.shared.unlockResult(reason: $0, approvedAccount: $1)
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
        guard case .popup(.getPendingRequests) = request.command else {
            return .command(.ignored(nil))
        }
        return .queue(presenter.pendingResponse())
    }

    func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        guard case .popup(let command) = request.command else {
            return .command(.ignored(nil))
        }
        if case .getPendingRequests = command {
            return await pendingRequestsResponse(profileIdentifier: profileIdentifier)
        }
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
            return .command(.ignored(nil))
        }
        switch command {
        case .getApprovalState, .retryApproval:
            let retry: Bool
            if case .retryApproval = command { retry = true }
            else { retry = false }
            return await commandResponse(
                for: .applied(),
                handle: handle,
                retry: retry
            )
        case .getPendingRequests:
            preconditionFailure()
        case .approveRequest, .rejectRequest, .setTransactionSpeed,
             .applyTransactionEdits, .resolveApprovalAlert:
            let outcome = await performCommand(
                command,
                request: request,
                profileIdentifier: profileIdentifier
            )
            return await commandResponse(for: outcome, handle: handle)
        }
    }

    private func commandResponse(
        for outcome: PopupCommandOutcome,
        handle: ExtensionBridge.Handle,
        retry: Bool = false
    ) async -> PopupResponse {
        if case .unavailable = outcome { return .command(.unavailable) }
        let loaded: ApprovalStateLoad
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            if retry, case .queued(_, .unowned) = snapshot.state {
                if sessions[handle]?.state == .error {
                    discardSession(handle: handle)
                }
                if immediateResponses[handle]?.state == .failed {
                    immediateResponses[handle] = nil
                }
            }
            loaded = await approvalState(snapshot: snapshot)
        case .missing:
            loaded = .available(presenter.missingState(id: handle.id))
        case .unavailable:
            loaded = .unavailable
        }
        guard case .available(var state) = loaded else {
            return .command(.unavailable)
        }
        switch outcome {
        case .applied(let editsError):
            state.editsError = editsError
            return .command(.ok(state))
        case .ignored:
            return .command(.ignored(state))
        case .unavailable:
            return .command(.unavailable)
        }
    }

    private func performCommand(
        _ command: InternalSafariRequest.PopupCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupCommandOutcome {
        switch command {
        case .approveRequest(_, let payload):
            return await approve(
                request: request,
                profileIdentifier: profileIdentifier,
                payload: payload
            )
        case .rejectRequest:
            return await reject(request: request, profileIdentifier: profileIdentifier)
        case .setTransactionSpeed, .applyTransactionEdits, .resolveApprovalAlert:
            switch await mutableSession(for: request, profileIdentifier: profileIdentifier) {
            case .available(let context):
                switch command {
                case .setTransactionSpeed(_, let payload):
                    guard payload.value.isFinite else { return .ignored }
                    return setTransactionSpeed(session: context, payload: payload)
                case .applyTransactionEdits(_, let payload):
                    return applyTransactionEdits(session: context, payload: payload)
                case .resolveApprovalAlert(_, let payload):
                    return resolveApprovalAlert(session: context, payload: payload)
                default:
                    preconditionFailure()
                }
            case .ignored: return .ignored
            case .unavailable: return .unavailable
            }
        case .getPendingRequests, .getApprovalState, .retryApproval:
            preconditionFailure()
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

    private func refreshWalletsAndNetworks() -> WalletReviewCatalog? {
        invalidateNetworkCache()
        return walletEnvironment.currentReviewCatalog()
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
        return .queue(presenter.pendingResponse(
            requests: requests,
            completedResponses: completedResponses
        ))
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
               let reviewedAccess = session.reviewCatalog {
                guard let currentAccess = walletEnvironment.currentReviewCatalog() else {
                    discardSession(handle: snapshot.handle)
                    return .secureSetupRequired
                }
                if currentAccess.identity !=
                    reviewedAccess.identity {
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
        var preparedCatalog: WalletReviewCatalog?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else {
            guard let walletAccess = walletEnvironment.currentReviewCatalog() else {
                return .secureSetupRequired
            }
            preparedCatalog = walletAccess
            preparation = requestProcessor.prepare(
                request,
                catalog: walletAccess
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
                reviewCatalog: preparedCatalog
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
        return .available(session)
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
        snapshot: ExtensionBridge.Snapshot
    ) async -> ApprovalStateLoad {
        let handle = snapshot.handle
        if snapshot.phase == .responded {
            discardSession(handle: handle)
            immediateResponses[handle] = nil
            return .available(presenter.missingState(id: handle.id))
        }
        if snapshot.isQueuedForNativeApproval {
            discardSession(handle: handle)
            immediateResponses[handle] = nil
            return .available(presenter.state(id: handle.id, state: .working, host: snapshot.host))
        }
        let sessionWasCached = sessions[handle] != nil
        let activeSession = activeSession(snapshot: snapshot)
        guard case .available(let session) = activeSession else {
            if case .secureSetupRequired = activeSession {
                return .available(presenter.secureSetupRequiredState(
                    id: handle.id,
                    host: snapshot.host
                ))
            }
            if case .immediateResponse(let persistenceState) = activeSession {
                if persistenceState == .failed {
                    return .available(PopupApprovalStatePresenter.errorState(
                        id: handle.id,
                        host: snapshot.host,
                        error: Strings.failedToLoad
                    ))
                }
                return .available(presenter.state(id: handle.id, state: .working, host: snapshot.host))
            }
            if snapshot.phase == .approving {
                return .available(presenter.state(id: handle.id, state: .working, host: snapshot.host))
            }
            switch await store.load(handle: handle) {
            case .found(let current) where current.phase == .responded:
                discardSession(handle: handle)
                immediateResponses[handle] = nil
            case .found, .missing:
                break
            case .unavailable:
                return .unavailable
            }
            return .available(presenter.missingState(id: handle.id))
        }
        if session.state == .error {
            return .available(PopupApprovalStatePresenter.errorState(
                id: handle.id,
                host: snapshot.host,
                error: session.errorText ?? Strings.failedToLoad
            ))
        }
        if session.state != .review {
            return .available(presenter.state(id: handle.id, state: session.state, host: snapshot.host))
        }
        let action = session.reviewAction
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
        return .available(presenter.approvalState(
            for: session,
            action: action,
            transactionMutationAllowed: transactionMutationAllowed
        ))
    }

    private func approve(
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        payload: InternalSafariRequest.ApprovalPayload
    ) async -> PopupCommandOutcome {
        let snapshot: ExtensionBridge.Snapshot
        switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
        case .found(let value): snapshot = value
        case .missing: return .ignored
        case .unavailable: return .unavailable
        }
        guard snapshot.phase != .responded,
              case .available(let session) = activeSession(snapshot: snapshot),
              reviewToken(for: request) == session.reviewToken,
              session.canBeginApproval else {
            return .ignored
        }
        let action = session.reviewAction
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
            return .ignored
        }
        switch action {
        case .selectAccount(let selectAction), .switchAccount(let selectAction):
            guard let selectedAccounts = payload.selectedAccounts else {
                return .ignored
            }
            return await approveAccountSelection(
                session: session,
                action: selectAction,
                selectedAccounts: selectedAccounts,
                chainId: payload.chainId
            ) ? .applied() : .ignored
        case .approveMessage(let signAction):
            guard let executionDeadline = payload.executionDeadline,
                  await approveMessageSigning(
                session: session,
                action: signAction,
                cluster: payload.cluster,
                expectedRevisions: payload.revisions,
                executionDeadline: executionDeadline
            ) else { return .ignored }
        case .approveTransaction:
            guard let executionDeadline = payload.executionDeadline,
                  session.transaction?.snapshot.canApprove == true else {
                return .ignored
            }
            guard await runSigningApproval(
                session: session,
                action: action,
                cluster: nil,
                expectedRevisions: payload.revisions,
                executionDeadline: executionDeadline
            ) else { return .ignored }
        case .addEthereumChain:
            guard let approval = await beginAndClaimApproval(for: session) else {
                return .ignored
            }
            await beginExecution(
                claim: approval.claim,
                for: session,
                token: approval.token
            ) {
                await self.executeDecision(
                    request: session.request,
                    action: action,
                    decision: .addEthereumChain
                )
            }
        }
        return .applied()
    }

    private func completeStaleApproval(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) async -> PopupCommandOutcome {
        guard snapshot.phase == .queued else { return .ignored }
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
            return .applied()
        case .ownershipLost:
            discardSession(handle: snapshot.handle)
            return .ignored
        case .retryablePersistenceFailure:
            session.fail(Strings.failedToLoad)
            return .unavailable
        }
    }

    private func approveAccountSelection(
        session: PopupRequestSession,
        action: SelectAccountAction,
        selectedAccounts: [InternalSafariRequest.SelectedAccount],
        chainId: String?
    ) async -> Bool {
        guard let reviewedCatalog = session.reviewCatalog else {
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
            accounts: reviewedCatalog.orderedAccounts,
            networkResolver: selectionNetworkResolver
        ) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        session.selectionDraft = .init(
            selectedAccounts: Set(resolved.accounts),
            network: resolved.network
        )
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        guard let refreshedCatalog = refreshWalletsAndNetworks() else {
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        guard refreshedCatalog.identity == reviewedCatalog.identity else {
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
            accounts: refreshedCatalog.orderedAccounts,
            networkResolver: selectionNetworkResolver
        ) else {
            session.selectionDraft = .init(
                selectedAccounts: [],
                network: (selection.ethereumChainID ?? action.network?.chainIdHexString)
                    .flatMap(selectionNetworkResolver)
            )
            session.setFeedback(Strings.somethingWentWrong)
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        session.selectionDraft = .init(
            selectedAccounts: Set(refreshed.accounts),
            network: refreshed.network
        )
        let approvedAction = session.reviewAction
        await beginExecution(
            claim: approval.claim,
            for: session,
            token: approval.token
        ) {
            await self.executeDecision(
                request: session.request,
                action: approvedAction,
                decision: .accountSelection(selection)
            )
        }
        return true
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
            decision: .message(.init(
                approvedAccount: WalletAccountDescriptor(walletID: action.walletId, account: action.account),
                solanaCluster: cluster
            )),
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
        let approvedAccount: WalletAccountDescriptor
        let transactionSession: PopupTransactionSession?
        switch action {
        case .approveMessage(let message):
            reason = message.subject.title
            approvedAccount = WalletAccountDescriptor(walletID: message.walletId, account: message.account)
            transactionSession = nil
        case .approveTransaction(let transactionAction):
            reason = Strings.sendTransaction
            approvedAccount = WalletAccountDescriptor(walletID: transactionAction.walletId, account: transactionAction.account)
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
            reason: reason,
            approvedAccount: approvedAccount
        )
        guard case .unlocked(let catalog, let signer) = authentication else {
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
        defer { signer.invalidate() }
        let decision: DappApprovalDecision
        if let transactionSession, let transactionToken,
           case .approveTransaction(let reviewedAction) = action {
            guard clock() < executionDeadline else {
                await releaseApproval(
                    approval.claim, for: session, token: approval.token,
                    rematerializeOnSuccess: true
                )
                return true
            }
            let timeout = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(max(
                        0, executionDeadline.timeIntervalSince(self.clock())
                    )))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                signer.invalidate()
                transactionSession.invalidate()
            }
            let preflight = await transactionSession.finishAuthentication(
                token: transactionToken,
                succeeded: true
            )
            timeout.cancel()
            switch preflight {
            case .approved(let transaction):
                guard let execution = DappApprovalDecision.TransactionExecution(
                    transaction,
                    reviewedNetwork: reviewedAction.resolvedNetwork,
                    approvedAccount: approvedAccount
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
            decision = .message(.init(approvedAccount: approvedAccount, solanaCluster: cluster))
        }
        guard case .valid = await validateSigningAccess(
            for: session,
            reviewedAction: action,
            approval: approval,
            catalog: catalog,
            signer: signer,
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
            acquireWalletLease: { await signer.takeExecutionLease() }
        ) {
            await self.executeDecision(
                request: session.request,
                action: action,
                decision: decision,
                signing: SigningExecutionContext(
                    access: signer, handle: session.handle, deadline: executionDeadline
                )
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
        catalog: WalletReviewCatalog,
        signer: RequestScopedWalletAccess,
        expectedRevisions: ExtensionBridge.ProviderRevisions?,
        executionDeadline: Date
    ) async -> SigningValidation {
        guard isCurrent(session, token: approval.token) else { return .superseded }
        let approvedAccount: WalletAccountDescriptor
        switch reviewedAction {
        case .approveMessage(let action):
            approvedAccount = WalletAccountDescriptor(walletID: action.walletId, account: action.account)
        case .approveTransaction(let action):
            approvedAccount = WalletAccountDescriptor(walletID: action.walletId, account: action.account)
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
              session.reviewCatalog?.identity == catalog.identity,
              signer.approvedAccount == approvedAccount,
              signer.validateCurrent(),
              catalog.orderedAccounts.contains(where: {
                  approvedAccount.matches(walletID: $0.walletId, account: $0.account)
              }),
              networkMatches else {
            return .reviewChanged
        }
        return isCurrent(session, token: approval.token) ? .valid : .superseded
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
        reason: String,
        approvedAccount: WalletAccountDescriptor
    ) async -> AuthenticationOutcome {
        guard session.beginAuthentication(
            claim: approval.claim,
            token: approval.token
        ) else { return .superseded }
        let outcome = await authenticate(session: session, reason: reason, approvedAccount: approvedAccount)
        guard isCurrent(session, token: approval.token),
              session.finishAuthentication(
                claim: approval.claim,
                token: approval.token
              ) else {
            if case .unlocked(_, let signer) = outcome {
                signer.invalidate()
            }
            return .superseded
        }
        return outcome
    }

    private func authenticate(
        session: PopupRequestSession,
        reason: String,
        approvedAccount: WalletAccountDescriptor
    ) async -> AuthenticationOutcome {
        switch await walletEnvironment.unlock(reason, approvedAccount) {
        case .canceled:
            return .cancelled
        case .unavailable:
            guard let currentIdentity = walletEnvironment.currentReviewCatalog()?.identity,
                  currentIdentity == session.reviewCatalog?.identity else {
                return .reviewChanged
            }
            return .unavailable(feedback: Strings.somethingWentWrong)
        case .unlocked(let catalog, let signer):
            guard let reviewedIdentity = session.reviewCatalog?.identity,
                  catalog.identity == reviewedIdentity,
                  signer.approvedAccount == approvedAccount,
                  catalog.orderedAccounts.contains(where: {
                      approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                  }),
                  signer.validateCurrent() else {
                signer.invalidate()
                return .reviewChanged
            }
            return .unlocked(catalog: catalog, signer: signer)
        }
    }

    private func reject(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupCommandOutcome {
        let snapshot: ExtensionBridge.Snapshot
        switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
        case .found(let value): snapshot = value
        case .missing: return .ignored
        case .unavailable: return .unavailable
        }
        guard snapshot.phase == .queued else {
            return .ignored
        }
        switch await store.reject(handle: snapshot.handle) {
        case .persisted:
            discardSession(handle: snapshot.handle)
            immediateResponses[snapshot.handle] = nil
            return .applied()
        case .ownershipLost:
            return .ignored
        case .retryablePersistenceFailure:
            return .unavailable
        }
    }

    private func executeDecision(
        request: SafariRequest,
        action: DappRequestAction,
        decision: DappApprovalDecision,
        signing: SigningExecutionContext? = nil
    ) async -> DappExecutionResult {
        let accounts: [SpecificWalletAccount]?
        if case .accountSelection = decision {
            accounts = refreshWalletsAndNetworks()?.orderedAccounts
        } else {
            accounts = nil
        }
        guard case .success(let approval) = DappApprovalValidator.resolve(
            action: action,
            decision: decision,
            accounts: accounts,
            networkResolver: selectionNetworkResolver
        ) else { return .rollback }
        let executionSigner: (any WalletSigning)?
        if approval.signingAccount != nil {
            guard let signing,
                  let operation = ApprovedWalletSigningOperation(
                    request: request, approval: approval,
                    handle: signing.handle, deadline: signing.deadline
                  ), let bound = signing.access.bind(operation: operation) else { return .rollback }
            executionSigner = bound
        } else {
            executionSigner = nil
        }
        defer { executionSigner?.invalidate() }
        return await requestProcessor.execute(
            request: request,
            approval: approval,
            signer: executionSigner
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
        session: PopupRequestSession,
        payload: InternalSafariRequest.TransactionSpeedPayload
    ) -> PopupCommandOutcome {
        guard let transactionSession = session.transaction else {
            return .ignored
        }
        transactionSession.setSpeed(payload)
        return .applied()
    }

    private func applyTransactionEdits(
        session: PopupRequestSession,
        payload: InternalSafariRequest.TransactionEditsPayload
    ) -> PopupCommandOutcome {
        guard let transactionSession = session.transaction,
              case .approveTransaction(let action) = session.preparedAction else {
            return .ignored
        }
        guard transactionSession.applyEdits(payload, chain: action.chain) else {
            return .applied(editsError: true)
        }
        return .applied()
    }

    private func resolveApprovalAlert(
        session: PopupRequestSession,
        payload: InternalSafariRequest.ApprovalAlertPayload
    ) -> PopupCommandOutcome {
        guard let transactionSession = session.transaction,
              transactionSession.resolveAlert(
                  action: payload.action
              ) else {
            return .ignored
        }
        return .applied()
    }


}
