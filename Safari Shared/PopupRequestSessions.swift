// ∅ 2026 lil org

import Foundation

@MainActor
final class PopupRequestSession {

    enum Presentation {
        case review(ReviewPresentation)
        case authenticating, working
        case error(message: String)
    }

    struct ReviewPresentation {
        let reviewToken: UUID
        let content: ReviewContent
        let reviewCatalog: WalletReviewCatalog?
        let feedback: String?
    }

    enum ReviewContent {
        case selectAccount(SelectAccountAction)
        case switchAccount(SelectAccountAction)
        case approveMessage(SignMessageAction)
        case approveTransaction(action: SendTransactionAction, transaction: PopupTransactionSession)
        case addEthereumChain(AddEthereumChainAction)

        var action: DappRequestAction {
            switch self {
            case .selectAccount(let action): .selectAccount(action)
            case .switchAccount(let action): .switchAccount(action)
            case .approveMessage(let action): .approveMessage(action)
            case .approveTransaction(let action, _): .approveTransaction(action)
            case .addEthereumChain(let action): .addEthereumChain(action)
            }
        }
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
        case working(feedback: String?)
        case authenticating(feedback: String?)
        case error(message: String)
    }

    let handle: ExtensionBridge.Handle
    let request: SafariRequest
    let reviewCatalog: WalletReviewCatalog?
    fileprivate let preparedContent: ReviewContent
    private var approvalReview: ApprovalReview
    var selectionDraft: SelectionDraft?
    private var lifecycle: Lifecycle
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0

    var binding: ExtensionBridge.RequestBinding { approvalReview.binding }
    var preparedAction: DappRequestAction { preparedContent.action }
    var transaction: PopupTransactionSession? {
        guard case .approveTransaction(_, let transaction) = preparedContent else { return nil }
        return transaction
    }

    init(
        intent: BoundApprovalIntent,
        reviewCatalog: WalletReviewCatalog? = nil,
        transactionApprovalOperations: TransactionApprovalOperations
    ) {
        handle = intent.binding.handle
        request = intent.binding.request
        switch intent.action {
        case .selectAccount(let action):
            preparedContent = .selectAccount(action)
        case .switchAccount(let action):
            preparedContent = .switchAccount(action)
        case .approveMessage(let action):
            preparedContent = .approveMessage(action)
        case .approveTransaction(let action):
            preparedContent = .approveTransaction(
                action: action,
                transaction: PopupTransactionSession(action: action, operations: transactionApprovalOperations)
            )
        case .addEthereumChain(let action):
            preparedContent = .addEthereumChain(action)
        }
        approvalReview = ApprovalReview(intent: intent)
        self.reviewCatalog = reviewCatalog
        lifecycle = .review(feedback: nil)
    }

    func acceptAccounts(_ selection: DappApprovalDecision.AccountSelection, approvedAt: Date) -> ReviewConsent? {
        guard case .working = lifecycle else { return nil }
        return approvalReview.acceptAccounts(selection: selection, approvedAt: approvedAt)
    }

    func acceptMessage(cluster: Solana.Cluster?, approvedAt: Date) -> ReviewConsent? {
        guard case .working = lifecycle else { return nil }
        return approvalReview.acceptMessage(cluster: cluster, approvedAt: approvedAt)
    }

    func acceptTransaction(_ execution: DappApprovalDecision.TransactionExecution, approvedAt: Date) -> ReviewConsent? {
        guard case .working = lifecycle else { return nil }
        return approvalReview.acceptTransaction(execution: execution, approvedAt: approvedAt)
    }

    func acceptAddEthereumChain(approvedAt: Date) -> ReviewConsent? {
        guard case .working = lifecycle else { return nil }
        return approvalReview.acceptAddEthereumChain(approvedAt: approvedAt)
    }

    func invalidate() {
        approvalReview.invalidate()
        transaction?.invalidate()
    }

    private func renewApprovalReview() {
        approvalReview.invalidate()
        approvalReview = approvalReview.renewed()
    }

    var presentation: Presentation {
        switch lifecycle {
        case .review(let feedback):
            return .review(ReviewPresentation(
                reviewToken: reviewToken,
                content: reviewContent,
                reviewCatalog: reviewCatalog,
                feedback: feedback
            ))
        case .claiming, .working:
            return .working
        case .authenticating:
            return .authenticating
        case .error(let message):
            return .error(message: message)
        }
    }

    var hasActiveClaim: Bool {
        switch lifecycle {
        case .working, .authenticating:
            return true
        case .review, .claiming, .error:
            return false
        }
    }

    var errorText: String? {
        switch lifecycle {
        case .review(let feedback):
            return feedback
        case .working(let feedback), .authenticating(let feedback):
            return feedback
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
        case .working:
            lifecycle = .working(feedback: message)
        case .authenticating:
            lifecycle = .authenticating(feedback: message)
        case .error:
            lifecycle = .error(message: message)
        case .claiming:
            break
        }
    }

    var reviewAction: DappRequestAction { reviewContent.action }

    private var reviewContent: ReviewContent {
        guard let selectionDraft else { return preparedContent }
        switch preparedContent {
        case .selectAccount(let action):
            return .selectAccount(selectionDraft.applying(to: action))
        case .switchAccount(let action):
            return .switchAccount(selectionDraft.applying(to: action))
        case .approveMessage, .approveTransaction, .addEthereumChain:
            return preparedContent
        }
    }

    var canBeginApproval: Bool {
        if case .review = lifecycle { return true }
        return false
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

    func acceptClaim(token: UUID) -> Bool {
        guard case .claiming = lifecycle, isCurrent(token) else { return false }
        lifecycle = .working(feedback: nil)
        return true
    }

    func beginAuthentication(token: UUID) -> Bool {
        guard case .working(let feedback) = lifecycle,
              isCurrent(token) else {
            return false
        }
        lifecycle = .authenticating(feedback: feedback)
        return true
    }

    func finishAuthentication(token: UUID) -> Bool {
        guard case .authenticating(let feedback) = lifecycle,
              isCurrent(token) else {
            return false
        }
        lifecycle = .working(feedback: feedback)
        return true
    }

    func returnToReview(token: UUID) -> Bool {
        guard isCurrent(token) else { return false }
        renewApprovalReview()
        reviewToken = UUID()
        lifecycle = .review(feedback: errorText)
        return true
    }

    func fail(_ message: String, token: UUID? = nil) {
        guard token.map(isCurrent) ?? true else { return }
        lifecycle = .error(message: message)
    }

    func rotateReviewToken() {
        presentationRevision &+= 1
        guard case .review = lifecycle else { return }
        renewApprovalReview()
        reviewToken = UUID()
    }

}

@MainActor
final class PopupRequestSessions {

    private enum AuthenticationOutcome: Sendable {
        case unlocked(catalog: WalletReviewCatalog, session: WalletSigningSession)
        case abandoned(feedback: String?)
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

    private enum RequestEntry {
        case session(PopupRequestSession)
        case immediateResponse(ImmediateResponsePersistence)

        var session: PopupRequestSession? {
            guard case .session(let session) = self else { return nil }
            return session
        }
    }

#if os(iOS) || os(visionOS)
    static let shared = PopupRequestSessions(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor(),
        walletEnvironment: PopupWalletEnvironment(
            reviewCatalog: { SafariApprovalVault.shared.reviewCatalog() },
            unlockWallets: {
                await SafariApprovalVault.shared.unlockResult(reason: $0, authorization: $1)
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
    private var entries = [ExtensionBridge.Handle: RequestEntry]()

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
        broadcastSender: (any ApprovedBroadcastSending)? = nil,
        broadcastTimeoutNanoseconds: UInt64 =
            DurableApprovalExecutor.defaultBroadcastTimeoutNanoseconds,
        clock: @escaping () -> Date = Date.init,
        waitForExecutionDeadline: (@MainActor (Date) async -> Void)? = nil
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
            requestProcessor: requestProcessor,
            broadcastSender: broadcastSender,
            broadcastTimeoutNanoseconds: broadcastTimeoutNanoseconds,
            clock: clock,
            waitForExecutionDeadline: waitForExecutionDeadline
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
            return .command(.init(status: .ignored, approvalState: nil))
        }
        return .queue(presenter.pendingResponse())
    }

    func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupResponse {
        guard case .popup(let command) = request.command else {
            return .command(.init(status: .ignored, approvalState: nil))
        }
        if case .getPendingRequests = command {
            return await pendingRequestsResponse(profileIdentifier: profileIdentifier)
        }
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
            return .command(.init(status: .ignored, approvalState: nil))
        }
        switch command {
        case .getApprovalState, .retryApproval:
            let retry: Bool
            if case .retryApproval = command { retry = true }
            else { retry = false }
            return await commandResponse(
                for: .ok(),
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
        for outcome: PopupCommandStatus,
        handle: ExtensionBridge.Handle,
        retry: Bool = false
    ) async -> PopupResponse {
        if case .unavailable = outcome {
            return .command(.init(status: .unavailable, approvalState: nil))
        }
        let loaded: PopupApprovalState?
        switch await store.load(handle: handle) {
        case .found(let snapshot):
            if retry, case .queued(_, .unowned) = snapshot.state {
                switch entries[handle] {
                case .session(let session):
                    if case .error = session.presentation {
                        discardSession(handle: handle)
                    }
                case .immediateResponse(let persistence) where persistence.state == .failed:
                    discardEntry(handle: handle)
                default:
                    break
                }
            }
            loaded = await approvalState(snapshot: snapshot)
        case .missing:
            loaded = presenter.missingState(id: handle.id)
        case .unavailable:
            loaded = nil
        }
        guard let state = loaded else {
            return .command(.init(status: .unavailable, approvalState: nil))
        }
        return .command(.init(status: outcome, approvalState: state))
    }

    private func performCommand(
        _ command: InternalSafariRequest.PopupCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupCommandStatus {
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
            let snapshot: ExtensionBridge.Snapshot
            switch await self.snapshot(for: request, profileIdentifier: profileIdentifier) {
            case .found(let value): snapshot = value
            case .missing: return .ignored
            case .unavailable: return .unavailable
            }
            guard let session = entries[snapshot.handle]?.session,
                  reviewToken(for: request) == session.reviewToken,
                  canMutateTransaction(snapshot: snapshot, session: session) else {
                return .ignored
            }
            switch command {
            case .setTransactionSpeed(_, let payload):
                guard payload.value.isFinite else { return .ignored }
                return setTransactionSpeed(session: session, payload: payload)
            case .applyTransactionEdits(_, let payload):
                return applyTransactionEdits(session: session, payload: payload)
            case .resolveApprovalAlert(_, let payload):
                return resolveApprovalAlert(session: session, payload: payload)
            default:
                preconditionFailure()
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
        let staleHandles = entries.compactMap { handle, entry -> ExtensionBridge.Handle? in
            guard handle.profileIdentifier == profileIdentifier,
                  !currentHandles.contains(handle),
                  entry.session?.hasActiveClaim != true else { return nil }
            return handle
        }
        staleHandles.forEach { discardEntry(handle: $0) }

        var requests = [PopupPendingRequest]()
        var completedResponses = [PopupCompletedResponse]()
        for snapshot in snapshots {
            switch snapshot.phase {
            case .queued, .approving:
                requests.append(presenter.pendingRequest(snapshot))
            case .responded:
                discardEntry(handle: snapshot.handle)
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
            discardEntry(handle: snapshot.handle)
            return .absent
        }
        if let session = entries[snapshot.handle]?.session {
            if snapshot.phase == .approving &&
                !session.hasActiveClaim {
                return .absent
            }
            if snapshot.phase == .queued,
               session.canBeginApproval,
               let reviewedAccess = session.reviewCatalog {
                guard let currentAccess = walletEnvironment.currentReviewCatalog() else {
                    discardSession(handle: snapshot.handle)
                    return .secureSetupRequired
                }
                if currentAccess.identity != reviewedAccess.identity ||
                    currentAccess.orderedAccounts != reviewedAccess.orderedAccounts {
                    discardSession(handle: snapshot.handle)
                    return ensureSession(snapshot: snapshot)
                }
            }
            return .available(session)
        }
        guard case .queued(_, .unowned) = snapshot.state,
              let binding = snapshot.requestBinding else { return .absent }
        if case .immediateResponse(let persistence) = entries[snapshot.handle] {
            return .immediateResponse(persistence.state)
        }
        let preparation: DappRequestPreparation
        var preparedCatalog: WalletReviewCatalog?
        if let walletIndependent = requestProcessor.prepareWithoutWallets(binding) {
            preparation = walletIndependent
        } else {
            guard let walletAccess = walletEnvironment.currentReviewCatalog() else {
                return .secureSetupRequired
            }
            preparedCatalog = walletAccess
            preparation = requestProcessor.prepare(
                binding,
                catalog: walletAccess
            )
        }
        switch preparation {
        case .immediate(let response):
            persistImmediateResponse(response, handle: snapshot.handle)
            return .immediateResponse(.working)
        case .approval(let intent):
            guard intent.binding == binding else { return .absent }
            let session = PopupRequestSession(
                intent: intent,
                reviewCatalog: preparedCatalog,
                transactionApprovalOperations: transactionApprovalOperations
            )
            entries[snapshot.handle] = .session(session)
            if case .approveTransaction(let action, let transaction) = session.preparedContent {
                setupTransaction(transaction, for: session, action: action)
            }
            return .available(session)
        }
    }

    private func persistImmediateResponse(
        _ response: ImmediateResolution,
        handle: ExtensionBridge.Handle
    ) {
        let persistence = ImmediateResponsePersistence()
        entries[handle] = .immediateResponse(persistence)
        Task { [weak self, store] in
            let result = await store.completeImmediate(handle: handle, resolution: response)
            guard let self,
                  case .immediateResponse(let current) = entries[handle],
                  current === persistence else { return }
            switch result {
            case .persisted, .ownershipLost:
                discardEntry(handle: handle)
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
        guard case .session = entries[handle] else { return }
        discardEntry(handle: handle)
    }

    private func discardEntry(handle: ExtensionBridge.Handle) {
        entries.removeValue(forKey: handle)?.session?.invalidate()
    }

    private func canMutateTransaction(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) -> Bool {
        return snapshot.phase == .queued &&
            session.handle == snapshot.handle &&
            session.canBeginApproval
    }

    private func approvalState(
        snapshot: ExtensionBridge.Snapshot
    ) async -> PopupApprovalState? {
        let handle = snapshot.handle
        if snapshot.phase == .responded {
            discardEntry(handle: handle)
            return presenter.missingState(id: handle.id)
        }
        if snapshot.isQueuedForNativeApproval {
            discardEntry(handle: handle)
            return presenter.state(id: handle.id, host: snapshot.host, presentation: .working)
        }
        let sessionWasCached = entries[handle]?.session != nil
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
                return presenter.state(id: handle.id, host: snapshot.host, presentation: .working)
            }
            if snapshot.phase == .approving {
                return presenter.state(id: handle.id, host: snapshot.host, presentation: .working)
            }
            switch await store.load(handle: handle) {
            case .found(let current) where current.phase == .responded:
                discardEntry(handle: handle)
            case .found, .missing:
                break
            case .unavailable:
                return nil
            }
            return presenter.missingState(id: handle.id)
        }
        if sessionWasCached, session.canBeginApproval {
            switch session.reviewAction {
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
        return presenter.state(
            id: handle.id,
            host: session.request.host,
            presentation: session.presentation,
            transactionMutationAllowed: transactionMutationAllowed
        )
    }

    private func approve(
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        payload: InternalSafariRequest.ApprovalPayload
    ) async -> PopupCommandStatus {
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
        let authorityIsCurrent = await store.authorityIsCurrent(handle: snapshot.handle)
        guard entries[snapshot.handle]?.session === session,
              reviewToken(for: request) == session.reviewToken,
              session.canBeginApproval else {
            return .ignored
        }
        guard authorityIsCurrent else {
            return await completeStaleApproval(snapshot: snapshot, session: session)
        }
        let action = session.reviewAction
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
            ) ? .ok() : .ignored
        case .approveMessage(let signAction):
            guard await approveMessageSigning(
                session: session,
                action: signAction,
                cluster: payload.cluster
            ) else { return .ignored }
        case .approveTransaction:
            guard session.transaction?.snapshot.canApprove == true else {
                return .ignored
            }
            guard await runSigningApproval(
                session: session,
                action: action,
                cluster: nil
            ) else { return .ignored }
        case .addEthereumChain:
            var accepted = true
            let claimed = await runClaimedApproval(for: session) { _, _ in
                guard let consent = session.acceptAddEthereumChain(approvedAt: self.clock()) else {
                    accepted = false
                    return .abandon
                }
                return .ready(consent: consent, signing: .none)
            }
            guard claimed, accepted else { return .ignored }
        }
        return .ok()
    }

    private func completeStaleApproval(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) async -> PopupCommandStatus {
        guard snapshot.phase == .queued else { return .ignored }
        session.transaction?.invalidate()
        let resolution = ImmediateResolution.failure(ProviderResponseError(
            message: Strings.providerNotReady,
            code: 4100
        ))
        switch await store.completeImmediate(handle: snapshot.handle, resolution: resolution) {
        case .persisted:
            discardSession(handle: snapshot.handle)
            return .ok()
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
        var accounts = [WalletAccountDescriptor]()
        for selected in selectedAccounts {
            guard let coin = WalletCoin.correspondingToInpageProvider(selected.coin) else {
                session.setFeedback(Strings.somethingWentWrong)
                return true
            }
            accounts.append(WalletAccountDescriptor(
                walletID: selected.walletId,
                coin: coin,
                normalizedAddress: coin.normalizedAddress(selected.address),
                derivationPath: selected.derivationPath
            ))
        }
        let selection = DappApprovalDecision.AccountSelection(
            accounts: accounts,
            ethereumChainID: chainId
        )
        guard let resolved = DappApprovalValidator.resolveSelection(
            action: action,
            selection: selection,
            accounts: reviewedCatalog.orderedAccounts,
            network: (selection.ethereumChainID ?? action.network?.chainIdHexString)
                .flatMap(selectionNetworkResolver)
        ) else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        session.selectionDraft = .init(
            selectedAccounts: Set(resolved.accounts),
            network: resolved.network
        )
        var accepted = true
        let claimed = await runClaimedApproval(for: session) { _, _ in
            guard let refreshedCatalog = self.refreshWalletsAndNetworks() else {
                session.setFeedback(Strings.somethingWentWrong)
                return .abandon
            }
            guard refreshedCatalog.identity == reviewedCatalog.identity else {
                return .abandon
            }
            guard let refreshed = DappApprovalValidator.resolveSelection(
                action: action,
                selection: selection,
                accounts: refreshedCatalog.orderedAccounts,
                network: (selection.ethereumChainID ?? action.network?.chainIdHexString)
                    .flatMap(self.selectionNetworkResolver)
            ) else {
                session.selectionDraft = .init(
                    selectedAccounts: [],
                    network: (selection.ethereumChainID ?? action.network?.chainIdHexString)
                        .flatMap(self.selectionNetworkResolver)
                )
                session.setFeedback(Strings.somethingWentWrong)
                return .abandon
            }
            session.selectionDraft = .init(
                selectedAccounts: Set(refreshed.accounts),
                network: refreshed.network
            )
            let acceptedSelection = DappApprovalDecision.AccountSelection(
                accounts: selection.accounts,
                ethereumChainID: refreshed.network?.chainIdHexString ?? selection.ethereumChainID
            )
            guard let consent = session.acceptAccounts(acceptedSelection, approvedAt: self.clock()) else {
                accepted = false
                return .abandon
            }
            return .ready(consent: consent, signing: .none)
        }
        return claimed && accepted
    }

    private func approveMessageSigning(
        session: PopupRequestSession,
        action: SignMessageAction,
        cluster: Solana.Cluster?
    ) async -> Bool {
        guard DappApprovalValidator.resolveMessagePayload(action.payload, cluster: cluster) != nil else {
            session.setFeedback(Strings.somethingWentWrong)
            return true
        }
        return await runSigningApproval(
            session: session,
            action: .approveMessage(action),
            cluster: cluster
        )
    }

    private func runSigningApproval(
        session: PopupRequestSession,
        action: DappRequestAction,
        cluster: Solana.Cluster?
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
        return await runClaimedApproval(for: session) { context, token in
            let executionDeadline = context.executionDeadline
            let authorization = WalletSigningAuthorization(
                handle: context.handle,
                approvedAccount: approvedAccount,
                signingDeadline: executionDeadline
            )
            let transactionToken = transactionSession?.beginApproval()
            if transactionSession != nil && transactionToken == nil {
                return .abandon
            }
            let authentication = await self.authenticateClaimedSession(
                session: session,
                token: token,
                reason: reason,
                authorization: authorization,
                context: context
            )
            guard case .unlocked(let catalog, let signer) = authentication else {
                if let transactionSession, let transactionToken {
                    _ = await transactionSession.finishAuthentication(
                        token: transactionToken,
                        succeeded: false
                    )
                }
                if case .abandoned(let feedback?) = authentication,
                   self.isCurrent(session, token: token) {
                    session.setFeedback(feedback)
                }
                return .abandon
            }
            var untransferredSigner: WalletSigningSession? = signer
            defer { untransferredSigner?.invalidate() }
            let decision: DappApprovalDecision
            if let transactionSession, let transactionToken,
               case .approveTransaction(let reviewedAction) = action {
                let preflight = await context.runBeforeDeadline(onTimeout: {
                    signer.invalidate()
                    transactionSession.invalidate()
                }) {
                    await transactionSession.finishAuthentication(
                        token: transactionToken,
                        succeeded: true
                    )
                }
                guard case .value(let preflight) = preflight else { return .abandon }
                switch preflight {
                case .approved(let transaction):
                    guard let execution = DappApprovalDecision.TransactionExecution(
                        transaction,
                        reviewedNetwork: reviewedAction.resolvedNetwork,
                        approvedAccount: approvedAccount
                    ) else { return .abandon }
                    decision = .transaction(execution)
                case .reviewRequired:
                    return .abandon
                case .invalidated:
                    return .abandon
                }
            } else {
                decision = .message(.init(approvedAccount: approvedAccount, solanaCluster: cluster))
            }
            guard await self.validateSigningAccess(
                for: session,
                reviewedAction: action,
                token: token,
                catalog: catalog,
                signer: signer
            ) else { return .abandon }
            let consent: ReviewConsent?
            switch decision {
            case .transaction(let execution):
                consent = session.acceptTransaction(execution, approvedAt: self.clock())
            case .message(let message):
                consent = session.acceptMessage(cluster: message.solanaCluster, approvedAt: self.clock())
            case .accountSelection, .addEthereumChain:
                consent = nil
            }
            guard let consent else { return .abandon }
            untransferredSigner = nil
            return .ready(consent: consent, signing: .unlocked(signer))
        }
    }

    private func validateSigningAccess(
        for session: PopupRequestSession,
        reviewedAction: DappRequestAction,
        token: UUID,
        catalog: WalletReviewCatalog,
        signer: WalletSigningSession
    ) async -> Bool {
        guard isCurrent(session, token: token) else { return false }
        let authorityIsCurrent = await store.authorityIsCurrent(handle: session.handle)
        guard clock() < signer.authorization.signingDeadline else { return false }
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
        guard authorityIsCurrent,
              walletsAvailable,
              session.reviewCatalog?.identity == catalog.identity,
              signer.validateCurrent(),
              networkMatches else {
            return false
        }
        return isCurrent(session, token: token)
    }

    private func runClaimedApproval(
        for session: PopupRequestSession,
        prepare: @MainActor (DurableApprovalExecutor.ClaimContext, UUID) async -> DurableApprovalExecutor.Preparation
    ) async -> Bool {
        let presentationRevision = session.presentationRevision
        guard let token = session.beginApproval() else { return false }
        switch await store.claim(handle: session.handle) {
        case .claimed(let claim):
            var accepted = true
            let result = await durableApprovalExecutor.execute(claim: claim, prepare: { context in
                guard self.isCurrent(session, token: token),
                      session.acceptClaim(token: token) else {
                    accepted = false
                    return .abandon
                }
                guard session.presentationRevision == presentationRevision else {
                    accepted = false
                    return .abandon
                }
                return await prepare(context, token)
            }, resolve: { consent in
                let accounts: [SpecificWalletAccount]
                if case .addEthereumChain = consent.intent.action {
                    accounts = []
                } else {
                    guard let catalog = self.refreshWalletsAndNetworks() else { return .abandon }
                    accounts = catalog.orderedAccounts
                }
                guard self.isCurrent(session, token: token) else { return .abandon }
                let selectionNetwork: EthereumNetwork?
                switch (consent.intent.action, consent.decision) {
                case (.selectAccount(let action), .accountSelection(let selection)),
                     (.switchAccount(let action), .accountSelection(let selection)):
                    selectionNetwork = (selection.ethereumChainID ?? action.network?.chainIdHexString)
                        .flatMap(self.selectionNetworkResolver)
                default:
                    selectionNetwork = nil
                }
                let transactionNetwork: ResolvedEthereumNetwork?
                if case .approveTransaction(let action) = consent.intent.action {
                    transactionNetwork = self.signingNetworkResolver(action.chain.chainId)
                } else {
                    transactionNetwork = nil
                }
                guard case .success(let resolved) = consent.resolve(context: .init(
                    accounts: accounts,
                    selectionNetwork: selectionNetwork,
                    transactionNetwork: transactionNetwork
                )) else { return .abandon }
                return .approved(resolved)
            })
            await finishExecution(result, for: session, token: token)
            return accepted
        case .executing, .responded, .missing:
            if entries[session.handle]?.session === session {
                discardSession(handle: session.handle)
            }
        case .unavailable:
            if isCurrent(session, token: token) {
                session.invalidate()
                session.fail(Strings.failedToLoad, token: token)
            }
        }
        return false
    }

    private func authenticateClaimedSession(
        session: PopupRequestSession,
        token: UUID,
        reason: String,
        authorization: WalletSigningAuthorization,
        context: DurableApprovalExecutor.ClaimContext
    ) async -> AuthenticationOutcome {
        guard session.beginAuthentication(token: token) else { return .abandoned(feedback: nil) }
        let result = await context.runBeforeDeadline(discardValue: { outcome in
            if case .unlocked(_, let signer) = outcome { signer.invalidate() }
        }) {
            await self.authenticate(session: session, reason: reason, authorization: authorization)
        }
        let outcome: AuthenticationOutcome
        switch result {
        case .value(let value): outcome = value
        case .expired: outcome = .abandoned(feedback: nil)
        }
        guard isCurrent(session, token: token), session.finishAuthentication(token: token) else {
            if case .unlocked(_, let signer) = outcome {
                signer.invalidate()
            }
            return .abandoned(feedback: nil)
        }
        return outcome
    }

    private func authenticate(
        session: PopupRequestSession,
        reason: String,
        authorization: WalletSigningAuthorization
    ) async -> AuthenticationOutcome {
        switch await walletEnvironment.unlock(reason, authorization) {
        case .canceled:
            return .abandoned(feedback: nil)
        case .unavailable:
            guard let currentCatalog = walletEnvironment.currentReviewCatalog(),
                  currentCatalog.identity == session.reviewCatalog?.identity,
                  currentCatalog.orderedAccounts.contains(where: {
                      authorization.approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                  }) else {
                return .abandoned(feedback: nil)
            }
            return .abandoned(feedback: Strings.somethingWentWrong)
        case .unlocked(let catalog, let signer):
            guard let reviewedIdentity = session.reviewCatalog?.identity,
                  catalog.identity == reviewedIdentity,
                  signer.authorization == authorization,
                  catalog.orderedAccounts.contains(where: {
                      authorization.approvedAccount.matches(walletID: $0.walletId, account: $0.account)
                  }),
                  signer.validateCurrent() else {
                signer.invalidate()
                return .abandoned(feedback: nil)
            }
            return .unlocked(catalog: catalog, session: signer)
        }
    }

    private func reject(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupCommandStatus {
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
            discardEntry(handle: snapshot.handle)
            return .ok()
        case .ownershipLost:
            return .ignored
        case .retryablePersistenceFailure:
            return .unavailable
        }
    }

    private func finishExecution(
        _ result: DurableApprovalExecutor.Result,
        for session: PopupRequestSession,
        token: UUID
    ) async {
        switch result {
        case .persisted:
            if entries[session.handle]?.session === session {
                discardSession(handle: session.handle)
            }
            return
        case .ownershipLost:
            break
        case .abandoned:
            guard isCurrent(session, token: token) else { return }
            if session.transaction?.requiresUserCorrection == true,
               case .found(let snapshot) = await store.load(handle: session.handle),
               case .queued(_, .unowned) = snapshot.state,
               snapshot.requestBinding == session.binding,
               let catalog = refreshWalletsAndNetworks(),
               catalog.identity == session.reviewCatalog?.identity,
               case .approveTransaction(let action) = session.preparedAction,
               let network = signingNetworkResolver(action.chain.chainId),
               DappApprovalDecision.NetworkIdentity(network) == DappApprovalDecision.NetworkIdentity(action.resolvedNetwork),
               isCurrent(session, token: token) {
                _ = session.returnToReview(token: token)
                return
            }
        case .retryablePersistenceFailure:
            guard isCurrent(session, token: token) else { return }
            session.setFeedback(Strings.failedToLoad)
        }
        guard isCurrent(session, token: token) else { return }
        let feedback = session.errorText ?? Strings.approvalInterrupted
        session.invalidate()
        session.fail(feedback, token: token)
    }

    private func isCurrent(
        _ session: PopupRequestSession,
        token: UUID
    ) -> Bool {
        return entries[session.handle]?.session === session &&
            session.isCurrent(token)
    }

    private func setupTransaction(
        _ transactionSession: PopupTransactionSession,
        for session: PopupRequestSession,
        action: SendTransactionAction
    ) {
        transactionSession.onChange = { [weak self, weak session] in
            guard let self,
                  let session,
                  entries[session.handle]?.session === session else { return }
            session.rotateReviewToken()
        }
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
    ) -> PopupCommandStatus {
        guard let transactionSession = session.transaction else {
            return .ignored
        }
        transactionSession.setSpeed(payload)
        return .ok()
    }

    private func applyTransactionEdits(
        session: PopupRequestSession,
        payload: InternalSafariRequest.TransactionEditsPayload
    ) -> PopupCommandStatus {
        guard let transactionSession = session.transaction,
              case .approveTransaction(let action) = session.preparedAction else {
            return .ignored
        }
        guard transactionSession.applyEdits(payload, chain: action.chain) else {
            return .ok(editsError: true)
        }
        return .ok()
    }

    private func resolveApprovalAlert(
        session: PopupRequestSession,
        payload: InternalSafariRequest.ApprovalAlertPayload
    ) -> PopupCommandStatus {
        guard let transactionSession = session.transaction,
              transactionSession.resolveAlert(
                  action: payload.action
              ) else {
            return .ignored
        }
        return .ok()
    }


}
