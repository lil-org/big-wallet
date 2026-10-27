import WalletDomain
import WalletStorageSupport
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
        case selectAccount(action: SelectAccountAction, draft: SelectionDraft)
        case switchAccount(action: SelectAccountAction, draft: SelectionDraft)
        case approveMessage(SignMessageAction)
        case approveTransaction(action: SendTransactionAction, transaction: PopupTransactionSession)
        case addEthereumChain(AddEthereumChainAction)
    }

    struct SelectionDraft {
        let selectedAccounts: Set<SpecificWalletAccount>
        let network: EthereumNetwork?
    }

    private enum Lifecycle {
        case review(feedback: String?)
        case claiming
        case working(feedback: String?)
        case authenticating(feedback: String?)
        case error(message: String)
    }

    let reviewCatalog: WalletReviewCatalog?
    private var reviewContent: ReviewContent
    private var approvalReview: ApprovalReview
    private var lifecycle: Lifecycle
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0

    var binding: ExtensionBridge.RequestBinding { approvalReview.binding }
    var handle: RequestHandle { binding.handle }
    var request: SafariRequest { binding.request }
    var preparedAction: DappRequestAction { approvalReview.action }
    var selectionDraft: SelectionDraft? {
        switch reviewContent {
        case .selectAccount(_, let selection), .switchAccount(_, let selection): selection
        default: nil
        }
    }
    var transaction: PopupTransactionSession? {
        guard case .approveTransaction(_, let transaction) = reviewContent else { return nil }
        return transaction
    }

    init(
        intent: BoundApprovalIntent,
        reviewCatalog: WalletReviewCatalog? = nil,
        transactionApprovalOperations: TransactionApprovalOperations,
        hooks: AuthorityExecutionHooks = .none
    ) {
        switch intent.action {
        case .approveTransaction(let action):
            reviewContent = .approveTransaction(action: action,
                transaction: PopupTransactionSession(action: action, operations: transactionApprovalOperations))
        case .selectAccount(let action):
            reviewContent = .selectAccount(action: action,
                draft: SelectionDraft(selectedAccounts: action.selectedAccounts, network: action.network))
        case .switchAccount(let action):
            reviewContent = .switchAccount(action: action,
                draft: SelectionDraft(selectedAccounts: action.selectedAccounts, network: action.network))
        case .approveMessage(let action):
            reviewContent = .approveMessage(action)
        case .addEthereumChain(let action):
            reviewContent = .addEthereumChain(action)
        }
        approvalReview = ApprovalReview(intent: intent, hooks: hooks)
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

    @discardableResult
    func setSelection(accounts: Set<SpecificWalletAccount>, network: EthereumNetwork?) -> Bool {
        guard case .review = lifecycle else { return false }
        let draft = SelectionDraft(selectedAccounts: accounts, network: network)
        switch reviewContent {
        case .selectAccount(let action, _): reviewContent = .selectAccount(action: action, draft: draft)
        case .switchAccount(let action, _): reviewContent = .switchAccount(action: action, draft: draft)
        default: return false
        }
        return true
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
public final class PopupApprovalAuthority {

    private enum AuthenticationOutcome: Sendable {
        case unlocked(catalog: WalletReviewCatalog, preparation: WalletSigningPreparation)
        case authenticationCancelled
        case rejected(ImmediateResolution)
        case abandoned(feedback: String?)
    }

    private enum PreparationStop: Equatable, Sendable {
        case notAccepted, authenticationCancelled, feeCorrectionRequired
    }

    private enum ActiveSessionResult {
        case available(PopupRequestSession)
        case immediateResponse(ImmediateResponsePersistence.State)
        case absent
        case secureSetupRequired
        case unavailable
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

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let walletEnvironment: PopupWalletEnvironment
    private let transactionApprovalOperations: TransactionApprovalOperations
    private let loadsTransactionContext: Bool
    private let loadTransactionContext: @MainActor @Sendable (SendTransactionAction) async -> String?
    private let messages: AuthorityMessages
    private let hooks: AuthorityExecutionHooks
    private let invalidateNetworkCache: () -> Void
    private let selectionNetworkResolver: (String) -> EthereumNetwork?
    private let approvalNetworkResolver: (Int) -> ApprovalNetworkResolution
    private let customDefinitionResult: @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult
    private let clock: @MainActor @Sendable () -> Date
    private let durableApprovalExecutor: DurableApprovalExecutor
    private let approvalSubjectTitle: @MainActor @Sendable (ApprovalSubject) -> String
    private var entries = [RequestHandle: RequestEntry]()

    init(
        store: PopupRequestStore,
        walletEnvironment: PopupWalletEnvironment,
        loadsTransactionContext: Bool,
        transactionApprovalOperations: TransactionApprovalOperations,
        invalidateNetworkCache: @escaping () -> Void = {
            CustomNetworkCache.shared.invalidate()
        },
        selectionNetworkResolver: @escaping (String) -> EthereumNetwork?,
        approvalNetworkResolver: @escaping (Int) -> ApprovalNetworkResolution,
        executionEnvironment: DurableApprovalExecutor.Environment,
        approvalSubjectTitle: @escaping @MainActor @Sendable (ApprovalSubject) -> String,
        customDefinitionResult: @escaping @MainActor @Sendable (EthereumNetworkFromDapp) -> CustomNetworkInsertionResult,
        messages: AuthorityMessages,
        loadTransactionContext: @escaping @MainActor @Sendable (SendTransactionAction) async -> String? = { _ in nil }
    ) {
        self.store = store
        requestProcessor = executionEnvironment.requestProcessor
        self.walletEnvironment = walletEnvironment
        self.transactionApprovalOperations = transactionApprovalOperations
        self.loadsTransactionContext = loadsTransactionContext
        self.loadTransactionContext = loadTransactionContext
        self.messages = messages
        hooks = executionEnvironment.hooks
        self.invalidateNetworkCache = invalidateNetworkCache
        self.selectionNetworkResolver = selectionNetworkResolver
        self.approvalNetworkResolver = approvalNetworkResolver
        self.customDefinitionResult = customDefinitionResult
        clock = executionEnvironment.clock
        durableApprovalExecutor = DurableApprovalExecutor(
            store: store,
            environment: executionEnvironment
        )
        self.approvalSubjectTitle = approvalSubjectTitle
    }

    public func dispatch(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupAuthorityResponse {
        await AuthorityMessageContext.$current.withValue(messages) {
            await AuthorityExecutionHooks.$current.withValue(hooks) {
                await dispatchScoped(request: request, profileIdentifier: profileIdentifier)
            }
        }
    }

    private func dispatchScoped(
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async -> PopupAuthorityResponse {
        guard case .popup(let command) = request.command else {
            return .command(status: .ignored, state: nil)
        }
        if case .getPendingRequests = command {
            return await pendingRequestsResponse(profileIdentifier: profileIdentifier)
        }
        guard let handle = handle(for: request, profileIdentifier: profileIdentifier) else {
            return .command(status: .ignored, state: nil)
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
             .applyTransactionEdits, .retryTransaction:
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
        handle: RequestHandle,
        retry: Bool = false
    ) async -> PopupAuthorityResponse {
        if case .unavailable = outcome {
            return .command(status: .unavailable, state: nil)
        }
        let loaded: PopupAuthorityState?
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
            loaded = PopupAuthorityState(id: handle.id, content: .missing)
        case .unavailable:
            loaded = nil
        }
        guard let state = loaded else {
            return .command(status: .unavailable, state: nil)
        }
        return .command(status: outcome, state: state)
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
        case .setTransactionSpeed, .applyTransactionEdits, .retryTransaction:
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
            case .retryTransaction:
                return session.transaction?.retryPreparation() == true ? .ok() : .ignored
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
    ) -> RequestHandle? {
        guard let requestToken = request.requestToken else { return nil }
        return RequestHandle(
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
    ) async -> PopupAuthorityResponse {
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
        let staleHandles = entries.compactMap { handle, entry -> RequestHandle? in
            guard handle.profileIdentifier == profileIdentifier,
                  !currentHandles.contains(handle),
                  entry.session?.hasActiveClaim != true else { return nil }
            return handle
        }
        staleHandles.forEach { discardEntry(handle: $0) }

        var requests = [ExtensionBridge.Snapshot]()
        var completedResponses = [ExtensionBridge.Snapshot]()
        for snapshot in snapshots {
            switch snapshot.phase {
            case .queued, .approving:
                requests.append(snapshot)
            case .responded:
                discardEntry(handle: snapshot.handle)
                completedResponses.append(snapshot)
            }
        }
        return .queue(pending: requests, completed: completedResponses)
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
        guard case .prepared(let preparation, let preparedCatalog) = requestProcessor.prepare(
            binding,
            loadingCatalog: walletEnvironment.currentReviewCatalog
        ) else { return .secureSetupRequired }
        switch preparation {
        case .needsCatalog, .unavailable:
            return .unavailable
        case .immediate(let response):
            persistImmediateResponse(response, handle: snapshot.handle)
            return .immediateResponse(.working)
        case .approval(let intent):
            guard intent.binding == binding else { return .absent }
            let session = PopupRequestSession(
                intent: intent,
                reviewCatalog: preparedCatalog,
                transactionApprovalOperations: transactionApprovalOperations,
                hooks: hooks
            )
            entries[snapshot.handle] = .session(session)
            if case .approveTransaction(let action) = session.preparedAction,
               let transaction = session.transaction {
                setupTransaction(transaction, for: session, action: action)
            }
            return .available(session)
        }
    }

    private func persistImmediateResponse(
        _ response: ImmediateResolution,
        handle: RequestHandle
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

    private func discardSession(handle: RequestHandle) {
        guard case .session = entries[handle] else { return }
        discardEntry(handle: handle)
    }

    private func discardEntry(handle: RequestHandle) {
        entries.removeValue(forKey: handle)?.session?.invalidate()
    }

    private func canMutateTransaction(
        snapshot: ExtensionBridge.Snapshot,
        session: PopupRequestSession
    ) -> Bool {
        guard case .queued(_, .unowned) = snapshot.state else { return false }
        return snapshot.requestBinding == session.binding &&
            session.handle == snapshot.handle &&
            session.canBeginApproval
    }

    private func approvalState(
        snapshot: ExtensionBridge.Snapshot
    ) async -> PopupAuthorityState? {
        let handle = snapshot.handle
        if snapshot.phase == .responded {
            discardEntry(handle: handle)
            return PopupAuthorityState(id: handle.id, content: .missing)
        }
        if snapshot.isQueuedForNativeApproval {
            discardEntry(handle: handle)
            return PopupAuthorityState(id: handle.id, host: snapshot.host, content: .working)
        }
        let sessionWasCached = entries[handle]?.session != nil
        let activeSession = activeSession(snapshot: snapshot)
        guard case .available(let session) = activeSession else {
            if case .unavailable = activeSession {
                return PopupAuthorityState(id: handle.id, host: snapshot.host,
                    content: .error(message: AuthorityStrings.failedToLoad, actions: [.retry, .reject]))
            }
            if case .secureSetupRequired = activeSession {
                return PopupAuthorityState(id: handle.id, host: snapshot.host,
                    content: .error(message: AuthorityStrings.secureApprovalSetupRequired, actions: [.retry, .reject]))
            }
            if case .immediateResponse(let persistenceState) = activeSession {
                if persistenceState == .failed {
                    return PopupAuthorityState(id: handle.id, host: snapshot.host,
                        content: .error(message: AuthorityStrings.failedToLoad, actions: [.retry]))
                }
                return PopupAuthorityState(id: handle.id, host: snapshot.host, content: .working)
            }
            if snapshot.phase == .approving {
                return PopupAuthorityState(id: handle.id, host: snapshot.host, content: .working)
            }
            switch await store.load(handle: handle) {
            case .found(let current) where current.phase == .responded:
                discardEntry(handle: handle)
            case .found, .missing:
                break
            case .unavailable:
                return nil
            }
            return PopupAuthorityState(id: handle.id, content: .missing)
        }
        if sessionWasCached, session.canBeginApproval {
            switch session.preparedAction {
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
        return PopupAuthorityState(id: handle.id, host: session.request.host,
            content: session.publicPresentation,
            transactionMutationAllowed: transactionMutationAllowed)
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
        guard authorityIsCurrent else { return .unavailable }
        switch session.preparedAction {
        case .selectAccount(let selectAction), .switchAccount(let selectAction):
            guard let selectedAccounts = payload.selectedAccounts,
                  let selectionDraft = session.selectionDraft else {
                return .ignored
            }
            return await approveAccountSelection(
                session: session,
                action: selectAction,
                draft: selectionDraft,
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
                cluster: nil
            ) else { return .ignored }
        case .addEthereumChain:
            let accepted = await runClaimedApproval(for: session) { _, _ in
                guard let consent = session.acceptAddEthereumChain(approvedAt: self.clock()) else {
                    return .stopped(.notAccepted)
                }
                return .ready(consent: consent, signing: nil)
            }
            guard accepted else { return .ignored }
        }
        return .ok()
    }

    private func approveAccountSelection(
        session: PopupRequestSession,
        action: SelectAccountAction,
        draft: PopupRequestSession.SelectionDraft,
        selectedAccounts: [InternalSafariRequest.SelectedAccount],
        chainId: String?
    ) async -> Bool {
        guard let reviewedCatalog = session.reviewCatalog else {
            return false
        }
        var accounts = [WalletAccountDescriptor]()
        for selected in selectedAccounts {
            guard let coin = WalletCoin.correspondingToInpageProvider(selected.coin) else {
                session.setFeedback(AuthorityStrings.somethingWentWrong)
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
        let selectedChainID = selection.ethereumChainID ?? draft.network?.chainIdHexString
        guard let resolvedAccounts = DappApprovalValidator.resolveSelectionAccounts(
            action: action,
            selection: selection,
            accounts: reviewedCatalog.orderedAccounts
        ) else {
            session.setFeedback(AuthorityStrings.somethingWentWrong)
            return true
        }
        if !resolvedAccounts.isEmpty {
            let hasValidChainID = selectedChainID.flatMap { Int(hexString: $0) }.map { $0 > 0 } ?? false
            let requiresEthereumNetwork = resolvedAccounts.contains { $0.account.coin == .ethereum }
            guard selectedChainID == nil || hasValidChainID,
                  !requiresEthereumNetwork || hasValidChainID else {
                session.setFeedback(AuthorityStrings.somethingWentWrong)
                return true
            }
        }
        session.setSelection(
            accounts: Set(resolvedAccounts),
            network: selectedChainID.flatMap(selectionNetworkResolver)
        )
        return await runClaimedApproval(for: session) { _, _ in
            guard let consent = session.acceptAccounts(selection, approvedAt: self.clock()) else {
                return .stopped(.notAccepted)
            }
            return .ready(consent: consent, signing: nil)
        }
    }

    private func approveMessageSigning(
        session: PopupRequestSession,
        action: SignMessageAction,
        cluster: Solana.Cluster?
    ) async -> Bool {
        guard DappApprovalValidator.resolveMessagePayload(action.payload, cluster: cluster, endpoints: action.solanaEndpoints) != nil else {
            session.setFeedback(AuthorityStrings.somethingWentWrong)
            return true
        }
        return await runSigningApproval(
            session: session,
            cluster: cluster
        )
    }

    private func runSigningApproval(
        session: PopupRequestSession,
        cluster: Solana.Cluster?
    ) async -> Bool {
        let reason: String
        let approvedAccount: WalletAccountDescriptor
        let transactionSession: PopupTransactionSession?
        let action = session.preparedAction
        switch action {
        case .approveMessage(let message):
            reason = approvalSubjectTitle(message.subject)
            approvedAccount = WalletAccountDescriptor(walletID: message.walletId, account: message.account)
            transactionSession = nil
        case .approveTransaction(let transactionAction):
            guard let transaction = session.transaction else { return false }
            reason = AuthorityStrings.sendTransaction
            approvedAccount = WalletAccountDescriptor(walletID: transactionAction.walletId, account: transactionAction.account)
            transactionSession = transaction
        case .selectAccount, .switchAccount, .addEthereumChain:
            return false
        }
        return await runClaimedApproval(for: session) { context, token in
            let executionDeadline = context.executionDeadline
            let scope = WalletSigningScope(
                handle: context.handle,
                approvedAccount: approvedAccount,
                signingDeadline: executionDeadline
            )
            let transactionReservation = transactionSession?.reserveForPreflight()
            if transactionSession != nil && transactionReservation == nil {
                return .abandon
            }
            let authentication = await self.authenticateClaimedSession(
                session: session,
                token: token,
                reason: reason,
                scope: scope,
                context: context
            )
            guard case .unlocked(let catalog, let preparation) = authentication else {
                if let transactionSession, let transactionReservation {
                    transactionSession.releaseReservation(transactionReservation)
                }
                switch authentication {
                case .authenticationCancelled:
                    return .stopped(.authenticationCancelled)
                case .rejected(let resolution):
                    return .rejected(resolution)
                case .abandoned(let feedback):
                    if let feedback, self.isCurrent(session, token: token) {
                        session.setFeedback(feedback)
                    }
                case .unlocked:
                    break
                }
                return .abandon
            }
            var untransferredPreparation: WalletSigningPreparation? = preparation
            defer { untransferredPreparation?.invalidate() }
            let transactionExecution: DappApprovalDecision.TransactionExecution?
            if let transactionSession, let transactionReservation,
               case .approveTransaction(let reviewedAction) = action {
                let preflight = await context.runBeforeDeadline(onStop: {
                    preparation.invalidate()
                    transactionSession.invalidate()
                }) {
                    await transactionSession.preflight(transactionReservation)
                }
                guard case .value(let preflight) = preflight else { return .abandon }
                switch preflight {
                case .approved(let transaction):
                    guard let execution = DappApprovalDecision.TransactionExecution(
                        transaction,
                        reviewedNetwork: reviewedAction.resolvedNetwork,
                        approvedAccount: approvedAccount
                    ) else { return .abandon }
                    transactionExecution = execution
                case .reviewRequired:
                    return .stopped(.feeCorrectionRequired)
                case .invalidated:
                    return .abandon
                }
            } else {
                transactionExecution = nil
            }
            switch await self.validateSigningAccess(
                for: session, token: token, catalog: catalog, preparation: preparation
            ) {
            case .unlocked:
                break
            case .rejected(let resolution):
                return .rejected(resolution)
            case .authenticationCancelled, .abandoned:
                return .abandon
            }
            let consent: ReviewConsent?
            if let transactionExecution {
                consent = session.acceptTransaction(transactionExecution, approvedAt: self.clock())
            } else {
                consent = session.acceptMessage(cluster: cluster, approvedAt: self.clock())
            }
            guard let consent else { return .abandon }
            untransferredPreparation = nil
            return .ready(consent: consent, signing: preparation)
        }
    }

    private func validateSigningAccess(
        for session: PopupRequestSession,
        token: UUID,
        catalog: WalletReviewCatalog,
        preparation: WalletSigningPreparation
    ) async -> AuthenticationOutcome {
        guard isCurrent(session, token: token) else { return .abandoned(feedback: nil) }
        let authorityIsCurrent = await store.authorityIsCurrent(handle: session.handle)
        guard isCurrent(session, token: token), authorityIsCurrent,
              clock() < preparation.scope.signingDeadline else { return .abandoned(feedback: nil) }
        if let failure = signingAccountFailure(
            preparation.approvedAccount, request: session.request,
            catalog: walletEnvironment.currentApprovalCatalog()
        ) { return failure }
        guard session.reviewCatalog?.identity == catalog.identity,
              preparation.validateCurrent(), isCurrent(session, token: token) else {
            return .abandoned(feedback: nil)
        }
        return .unlocked(catalog: catalog, preparation: preparation)
    }

    private func signingAccountFailure(
        _ account: WalletAccountDescriptor,
        request: SafariRequest,
        catalog: WalletReviewCatalog?
    ) -> AuthenticationOutcome? {
        guard let catalog else { return .abandoned(feedback: nil) }
        switch DappApprovalResolver.signingAccountResolution(account, request: request, catalog: catalog) {
        case .immediate(let resolution): return .rejected(resolution)
        case .reviewRequired: return .abandoned(feedback: AuthorityStrings.somethingWentWrong)
        case nil: return nil
        case .approved, .abandon: return .abandoned(feedback: nil)
        }
    }

    private func runClaimedApproval(
        for session: PopupRequestSession,
        prepare: @MainActor (DurableApprovalExecutor.ClaimContext, UUID) async -> DurableApprovalExecutor.Preparation<PreparationStop>
    ) async -> Bool {
        let presentationRevision = session.presentationRevision
        guard let token = session.beginApproval() else { return false }
        switch await store.claim(handle: session.handle) {
        case .claimed(let claim):
            let outcome = await durableApprovalExecutor.execute(claim: claim, prepare: { context in
                guard self.isCurrent(session, token: token),
                      session.acceptClaim(token: token) else {
                    return .stopped(PreparationStop.notAccepted)
                }
                guard session.presentationRevision == presentationRevision else {
                    return .stopped(.notAccepted)
                }
                return await prepare(context, token)
            }, resolve: { consent in
                await DappApprovalResolver.resolve(
                    consent,
                    refreshWalletCatalog: { self.walletEnvironment.currentApprovalCatalog() },
                    networkResolver: self.approvalNetworkResolver,
                    customDefinitionResult: self.customDefinitionResult,
                    isCurrent: { self.isCurrent(session, token: token) }
                )
            })
            return await finishExecution(outcome, for: session, token: token)
        case .executing, .responded, .missing:
            if entries[session.handle]?.session === session {
                discardSession(handle: session.handle)
            }
        case .unavailable:
            if isCurrent(session, token: token) {
                session.invalidate()
                session.fail(AuthorityStrings.failedToLoad, token: token)
            }
        }
        return false
    }

    private func authenticateClaimedSession(
        session: PopupRequestSession,
        token: UUID,
        reason: String,
        scope: WalletSigningScope,
        context: DurableApprovalExecutor.ClaimContext
    ) async -> AuthenticationOutcome {
        guard session.beginAuthentication(token: token) else { return .abandoned(feedback: nil) }
        let result = await context.runBeforeDeadline(discardValue: { outcome in
            if case .unlocked(_, let preparation) = outcome { preparation.invalidate() }
        }) {
            await self.authenticate(session: session, reason: reason, scope: scope)
        }
        let outcome: AuthenticationOutcome
        switch result {
        case .value(let value): outcome = value
        case .stopped: outcome = .abandoned(feedback: nil)
        }
        guard !Task.isCancelled, isCurrent(session, token: token),
              session.finishAuthentication(token: token) else {
            if case .unlocked(_, let preparation) = outcome {
                preparation.invalidate()
            }
            return .abandoned(feedback: nil)
        }
        return outcome
    }

    private func authenticate(
        session: PopupRequestSession,
        reason: String,
        scope: WalletSigningScope
    ) async -> AuthenticationOutcome {
        switch await walletEnvironment.unlock(reason, scope) {
        case .canceled:
            return Task.isCancelled ? .abandoned(feedback: nil) : .authenticationCancelled
        case .unavailable:
            if let failure = signingAccountFailure(
                scope.approvedAccount, request: session.request,
                catalog: walletEnvironment.currentApprovalCatalog()
            ) { return failure }
            return .abandoned(feedback: AuthorityStrings.somethingWentWrong)
        case .unlocked(let catalog, let preparation):
            if let failure = signingAccountFailure(
                scope.approvedAccount, request: session.request, catalog: catalog
            ) {
                preparation.invalidate()
                return failure
            }
            guard let reviewedIdentity = session.reviewCatalog?.identity,
                  catalog.identity == reviewedIdentity,
                  preparation.scope == scope,
                  preparation.validateCurrent() else {
                preparation.invalidate()
                return .abandoned(feedback: nil)
            }
            return .unlocked(catalog: catalog, preparation: preparation)
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
        _ outcome: DurableApprovalExecutor.ExecutionOutcome<PreparationStop>,
        for session: PopupRequestSession,
        token: UUID
    ) async -> Bool {
        let accepted: Bool
        let persistenceFailed: Bool
        switch outcome {
        case .finished(.persisted):
            if entries[session.handle]?.session === session {
                discardSession(handle: session.handle)
            }
            return true
        case .finished(let result):
            accepted = true
            persistenceFailed = result == .retryablePersistenceFailure
        case .preparationStopped(let reason, let release):
            accepted = reason != .notAccepted
            if release == .persisted,
               reason == .feeCorrectionRequired || reason == .authenticationCancelled,
               await restoreReview(session: session, token: token, reason: reason) { return accepted }
            persistenceFailed = release == .retryablePersistenceFailure
        }
        guard isCurrent(session, token: token) else { return accepted }
        if persistenceFailed { session.setFeedback(AuthorityStrings.failedToLoad) }
        let feedback = session.errorText ?? AuthorityStrings.approvalInterrupted
        session.invalidate()
        session.fail(feedback, token: token)
        return accepted
    }

    private func restoreReview(
        session: PopupRequestSession,
        token: UUID,
        reason: PreparationStop
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent(session, token: token),
              case .found(let snapshot) = await store.load(handle: session.handle),
              case .queued(_, .unowned) = snapshot.state,
              await store.authorityIsCurrent(handle: session.handle),
              !Task.isCancelled, isCurrent(session, token: token) else { return false }
        guard snapshot.requestBinding == session.binding else {
            guard reason == .authenticationCancelled else { return false }
            discardSession(handle: session.handle)
            return true
        }
        guard let catalog = refreshWalletsAndNetworks(),
              let account = session.preparedAction.signingAccount else { return false }
        guard catalog.identity == session.reviewCatalog?.identity else {
            guard reason == .authenticationCancelled else { return false }
            discardSession(handle: session.handle)
            return true
        }
        switch catalog.availability(of: account) {
        case .available:
            break
        case .removed:
            guard reason == .authenticationCancelled else { return false }
            discardSession(handle: session.handle)
            return true
        case .unavailable:
            return false
        }
        switch session.preparedAction {
        case .approveTransaction(let action):
            switch approvalNetworkResolver(action.chain.chainId) {
            case .resolved(let network):
                guard DappApprovalDecision.NetworkIdentity(network) ==
                    DappApprovalDecision.NetworkIdentity(action.resolvedNetwork) else {
                    guard reason == .authenticationCancelled else { return false }
                    discardSession(handle: session.handle)
                    return true
                }
            case .missing:
                guard reason == .authenticationCancelled else { return false }
                discardSession(handle: session.handle)
                return true
            case .unavailable:
                return false
            }
            if reason == .authenticationCancelled,
               session.transaction?.snapshot.canApprove != true { return false }
        case .approveMessage where reason == .authenticationCancelled:
            break
        default:
            return false
        }
        guard !Task.isCancelled, isCurrent(session, token: token) else { return false }
        return session.returnToReview(token: token)
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
        let load = loadTransactionContext
        Task { [weak transactionSession] in
            transactionSession?.balance = await load(action)
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
        guard case .approveTransaction(let action) = session.preparedAction,
              let transactionSession = session.transaction else {
            return .ignored
        }
        guard transactionSession.applyEdits(payload, chain: action.chain) else {
            return .ok(editsError: true)
        }
        return .ok()
    }

}

