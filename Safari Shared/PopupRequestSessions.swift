// ∅ 2026 lil org

import Foundation

@MainActor
protocol PopupRequestProcessing {
    func prepare(_ request: SafariRequest) -> DappRequestPreparation
    func prepareWithoutWallets(_ request: SafariRequest) -> DappRequestPreparation?
}

extension PopupRequestProcessing {
    func prepareWithoutWallets(_ request: SafariRequest) -> DappRequestPreparation? {
        return nil
    }
}

struct ProductionPopupRequestProcessor: PopupRequestProcessing {
    func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        return DappRequestProcessor.prepare(request)
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

    enum AuthenticationMode: Equatable {
        case biometrics
        case password(String)
    }

    let handle: ExtensionBridge.Handle
    let request: SafariRequest
    private(set) var purpose: Purpose
    var errorText: String?
    var canUsePassword = false
    var transaction: PopupTransactionSession?
    private(set) var state: State
    private(set) var reviewToken = UUID()
    private(set) var presentationRevision: UInt64 = 0
    private(set) var approvalClaim: ExtensionBridge.ApprovalClaim?

    init(
        handle: ExtensionBridge.Handle,
        request: SafariRequest,
        purpose: Purpose,
        initialState: State = .review
    ) {
        self.handle = handle
        self.request = request
        self.purpose = purpose
        state = initialState
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
        guard state == .review else { return nil }
        state = .working
        errorText = nil
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
        guard state == .working, isCurrent(token) else { return false }
        approvalClaim = claim
        return true
    }

    func beginAuthentication(
        claim: ExtensionBridge.ApprovalClaim,
        token: UUID
    ) -> Bool {
        guard state == .working, isCurrent(token), approvalClaim == claim else {
            return false
        }
        state = .authenticating
        return true
    }

    func finishAuthentication(
        claim: ExtensionBridge.ApprovalClaim,
        token: UUID
    ) -> Bool {
        guard state == .authenticating, isCurrent(token), approvalClaim == claim else {
            return false
        }
        state = .working
        return true
    }

    func returnToReview(token: UUID) -> Bool {
        guard isCurrent(token) else { return false }
        approvalClaim = nil
        state = .review
        return true
    }

    func fail(_ message: String, token: UUID? = nil) {
        guard token.map(isCurrent) ?? true else { return }
        approvalClaim = nil
        errorText = message
        state = .error
    }

    func retry() {
        approvalClaim = nil
        errorText = nil
        state = .review
        reviewToken = UUID()
    }

    func rotateReviewToken() {
        presentationRevision &+= 1
        guard state == .review else { return }
        reviewToken = UUID()
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
    }

    private enum TransactionApprovalDecision {
        case refused
        case alert
        case transaction(Transaction)
    }

    private final class TransactionApprovalResolution {
        let token: UUID
        private var continuation: CheckedContinuation<TransactionApprovalDecision, Never>?
        private(set) var isAuthenticating = false

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

        func finish(with decision: TransactionApprovalDecision) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: decision)
        }
    }

    private final class BroadcastResolution {
        private var continuation: CheckedContinuation<ResponseToExtension, Never>?
        var sendTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<ResponseToExtension, Never>) {
            self.continuation = continuation
        }

        func finish(
            with response: ResponseToExtension,
            cancelSend: Bool = false
        ) {
            guard let continuation else { return }
            self.continuation = nil
            if cancelSend {
                sendTask?.cancel()
            } else {
                timeoutTask?.cancel()
            }
            sendTask = nil
            timeoutTask = nil
            continuation.resume(returning: response)
        }
    }

    private nonisolated static let broadcastTimeoutNanoseconds: UInt64 =
        120 * 1_000_000_000

    static let shared = PopupRequestSessions(
        store: ExtensionBridge.shared,
        requestProcessor: ProductionPopupRequestProcessor()
    )

    private let store: PopupRequestStore
    private let requestProcessor: PopupRequestProcessing
    private let authenticationOverride: ((PopupRequestSession, PopupRequestSession.AuthenticationMode, String, @escaping (Bool) -> Void) -> Void)?
    private let canUseBiometrics: () -> Bool
    private let attemptBiometrics: (
        String,
        @escaping (DeviceAuthentication.Outcome) -> Void
    ) -> Void
    private let transactionApprovalOperations: TransactionApprovalOperations
    private let managesWallets: Bool
    private let startWalletsManager: () -> Bool
    private let reloadWalletsManager: () -> Bool
    private let selectionStateRefresh: () -> Bool
    private let selectionAccountResolver: (InternalSafariRequest.SelectedAccount) -> SpecificWalletAccount?
    private let selectionNetworkResolver: (String) -> EthereumNetwork?
    private let broadcastTimeoutNanoseconds: UInt64
    private let walletsManager = WalletsManager.shared
    private let presenter: PopupApprovalStatePresenter
    private var sessions = [ExtensionBridge.Handle: PopupRequestSession]()
    private var transactionApprovalResolutions = [
        ExtensionBridge.Handle: TransactionApprovalResolution
    ]()
    private var didStartWalletsManager = false
    private var biometricInteractionUnavailable = false

    init(
        store: PopupRequestStore,
        requestProcessor: PopupRequestProcessing,
        authenticationOverride: ((PopupRequestSession, PopupRequestSession.AuthenticationMode, String, @escaping (Bool) -> Void) -> Void)? = nil,
        canUseBiometrics: @escaping () -> Bool = {
            DeviceAuthentication.canUseBiometrics
        },
        attemptBiometrics: @escaping (
            String,
            @escaping (DeviceAuthentication.Outcome) -> Void
        ) -> Void = { reason, completion in
            DeviceAuthentication.attemptBiometrics(
                reason: reason,
                completion: completion
            )
        },
        transactionApprovalOperations: TransactionApprovalOperations = .live(),
        managesWallets: Bool = true,
        walletManagerStart: (() -> Bool)? = nil,
        walletManagerReload: (() -> Bool)? = nil,
        selectionStateRefresh: (() -> Bool)? = nil,
        selectionAccountResolver: ((InternalSafariRequest.SelectedAccount) -> SpecificWalletAccount?)? = nil,
        selectionNetworkResolver: ((String) -> EthereumNetwork?)? = nil,
        broadcastTimeoutNanoseconds: UInt64 = PopupRequestSessions.broadcastTimeoutNanoseconds
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.authenticationOverride = authenticationOverride
        self.canUseBiometrics = canUseBiometrics
        self.attemptBiometrics = attemptBiometrics
        self.transactionApprovalOperations = transactionApprovalOperations
        self.broadcastTimeoutNanoseconds = broadcastTimeoutNanoseconds
        self.managesWallets = managesWallets
        let startWalletsManager = walletManagerStart ?? {
            WalletsManager.shared.start()
        }
        let reloadWalletsManager = walletManagerReload ?? {
            WalletsManager.shared.reloadFromStore()
        }
        self.startWalletsManager = startWalletsManager
        self.reloadWalletsManager = reloadWalletsManager
        presenter = PopupApprovalStatePresenter(walletsManager: walletsManager)
        self.selectionStateRefresh = selectionStateRefresh ?? {
            let walletsAvailable = !managesWallets || reloadWalletsManager()
            CustomNetworkCache.shared.invalidate()
            return walletsAvailable
        }
        self.selectionAccountResolver = selectionAccountResolver ?? { item in
            guard let coin = WalletCoin.correspondingToInpageProvider(item.coin),
                  let wallet = WalletsManager.shared.currentWallet(id: item.walletId),
                  let account = wallet.accounts.first(where: {
                      $0.coin == coin && $0.address == item.address
                  }) else {
                return nil
            }
            return SpecificWalletAccount(walletId: item.walletId, account: account)
        }
        self.selectionNetworkResolver = selectionNetworkResolver ?? {
            Networks.withChainIdHex($0)
        }
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
        handle: ExtensionBridge.Handle
    ) async -> DappAdmissionDisposition {
        return await shared.materializeAfterAdmission(handle: handle)
    }

    func materializeAfterAdmission(
        handle: ExtensionBridge.Handle
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
            break
        }
        guard let request = snapshot.request else { return .unavailable }
        let preparation: DappRequestPreparation
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else if requiresWalletsForPostAdmissionResponse(request) {
            guard prepareWalletsForNewSession() else { return .unavailable }
            preparation = requestProcessor.prepare(request)
        } else {
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
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
                return queued
            case .approving:
                return .approvalRequired
            case .responded:
                return .responseReady
            }
        case .missing, .unavailable:
            return .unavailable
        }
    }

    private func requiresWalletsForPostAdmissionResponse(
        _ request: SafariRequest
    ) -> Bool {
        guard case .ethereum(let body) = request.body,
              body.method == .switchEthereumChain else {
            return false
        }
        return !body.address.isEmpty
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

    private func prepareWalletsForNewSession() -> Bool {
        guard managesWallets else { return true }
        if didStartWalletsManager {
            return reloadWalletsManager()
        }
        didStartWalletsManager = true
        return startWalletsManager()
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
        if let session = sessions[snapshot.handle] {
            if snapshot.phase == .approving &&
                (snapshot.request == nil || session.approvalClaim == nil) {
                return .absent
            }
            return session.isImmediateResponsePersistence
                ? .absent
                : .available(session)
        }
        guard snapshot.phase == .queued,
              let request = snapshot.request else { return .absent }
        let preparation: DappRequestPreparation
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else {
            guard prepareWalletsForNewSession() else { return .unavailable }
            preparation = requestProcessor.prepare(request)
        }
        switch preparation {
        case .response(let response):
            guard snapshot.phase == .queued else { return .unavailable }
            let session = PopupRequestSession(
                handle: snapshot.handle,
                request: request,
                purpose: .immediateResponsePersistence,
                initialState: .working
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
            let session = PopupRequestSession(
                handle: snapshot.handle,
                request: request,
                purpose: .approval(action)
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
           !selectionStateRefresh() {
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
        guard approvalRevisionsMatch(
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
        let authenticationMode: PopupRequestSession.AuthenticationMode = payload.password
            .map(PopupRequestSession.AuthenticationMode.password) ?? .biometrics
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
            guard await approveMessageSigning(
                session: session,
                action: signAction,
                cluster: payload.cluster,
                authenticationMode: authenticationMode
            ) else { return ignoredResponse() }
        case .approveTransaction:
            guard let transactionSession = session.transaction,
                  transactionSession.snapshot.canApprove else {
                return ignoredResponse()
            }
            guard let approval = await beginAndClaimApproval(for: session) else {
                return ignoredResponse()
            }
            switch await transactionApprovalDecision(
                for: session,
                transactionSession: transactionSession,
                authenticationMode: authenticationMode,
                approval: approval
            ) {
            case .refused, .alert:
                await releaseApproval(
                    approval.claim,
                    for: session,
                    token: approval.token
                )
            case .transaction(let transaction):
                guard case .approveTransaction(let action) = session.approvalAction else {
                    await releaseApproval(
                        approval.claim,
                        for: session,
                        token: approval.token
                    )
                    return ["status": "ok"]
                }
                await beginExecution(
                    claim: approval.claim,
                    for: session,
                    token: approval.token
                ) {
                    await action.resolve(transaction)
                }
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

    private func approvalRevisionsMatch(
        action: DappRequestAction,
        request: SafariRequest,
        stored: ExtensionBridge.ProviderRevisions,
        current: ExtensionBridge.ProviderRevisions?
    ) -> Bool {
        if case .addEthereumChain = action { return true }
        guard let current else { return false }
        switch request.provider {
        case .ethereum:
            return stored.ethereum == current.ethereum
        case .solana:
            return stored.solana == current.solana
        case .unknown, .multiple:
            return stored == current
        }
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
        if let chainId,
           selectionNetworkResolver(chainId) == nil {
            return false
        }
        guard let resolved = resolvedSelectionAccounts(
            selectedAccounts,
            requiredCoin: action.coinType
        ) else {
            session.errorText = Strings.somethingWentWrong
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
            session.errorText = Strings.somethingWentWrong
            return true
        }
        if !resolved.isEmpty,
           !updatedAction.canSubmitSelection(network: network) {
            session.errorText = Strings.somethingWentWrong
            return true
        }
        guard let approval = await beginAndClaimApproval(for: session) else { return false }
        guard selectionStateRefresh() else {
            session.errorText = Strings.somethingWentWrong
            await releaseApproval(
                approval.claim,
                for: session,
                token: approval.token
            )
            return true
        }
        let refreshedNetwork = selectedChainId.flatMap(selectionNetworkResolver)
        guard let refreshedAccounts = resolvedSelectionAccounts(
            selectedAccounts,
            requiredCoin: action.coinType
        ) else {
            _ = session.replaceSelectionAction(
                selectionAction(
                    action,
                    selectedAccounts: [],
                    network: refreshedNetwork
                )
            )
            session.errorText = Strings.somethingWentWrong
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
            session.errorText = Strings.somethingWentWrong
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
        requiredCoin: WalletCoin?
    ) -> [SpecificWalletAccount]? {
        var resolved = [SpecificWalletAccount]()
        var selectedCoins = Set<WalletCoin>()
        resolved.reserveCapacity(selectedAccounts.count)
        for item in selectedAccounts {
            guard let coin = WalletCoin.correspondingToInpageProvider(item.coin),
                  requiredCoin == nil || coin == requiredCoin,
                  let account = selectionAccountResolver(item),
                  account.walletId == item.walletId,
                  account.account.coin == coin,
                  account.account.address == item.address,
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
        authenticationMode: PopupRequestSession.AuthenticationMode
    ) async -> Bool {
        if let clusterSelection = action.solanaClusterSelection {
            guard let selectedCluster = cluster else {
                session.errorText = Strings.somethingWentWrong
                return true
            }
            clusterSelection.selectedCluster = selectedCluster
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
        let succeeded = await authenticate(
            session: session,
            authenticationMode: authenticationMode,
            reason: action.subject.title
        )
        guard isCurrent(session, token: approval.token),
              session.finishAuthentication(
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
        guard succeeded else {
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
            await action.resolve(true)
        }
        return true
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
        authenticationMode: PopupRequestSession.AuthenticationMode,
        reason: String
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            var didComplete = false
            let completeOnce: (Bool) -> Void = { succeeded in
                guard !didComplete else { return }
                didComplete = true
                continuation.resume(returning: succeeded)
            }
            if let authenticationOverride {
                authenticationOverride(session, authenticationMode, reason, completeOnce)
                return
            }
            switch authenticationMode {
            case .password(let password):
                if DeviceAuthentication.verify(password: password) {
                    completeOnce(true)
                } else {
                    session.errorText = Strings.passwordDoesNotMatch
                    session.canUsePassword = true
                    completeOnce(false)
                }
            case .biometrics:
                guard !biometricInteractionUnavailable,
                      canUseBiometrics() else {
                    session.errorText = biometricInteractionUnavailable || session.canUsePassword
                        ? Strings.enterPassword
                        : nil
                    session.canUsePassword = true
                    completeOnce(false)
                    return
                }
                self.attemptBiometrics(reason) { outcome in
                    MainActor.assumeIsolated {
                        if outcome != .succeeded {
                            if outcome == .interactionUnavailable {
                                self.biometricInteractionUnavailable = true
                                session.errorText = Strings.enterPassword
                            } else {
                                session.errorText = nil
                            }
                            session.canUsePassword = true
                        }
                        completeOnce(outcome == .succeeded)
                    }
                }
            }
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
        authenticationMode: PopupRequestSession.AuthenticationMode,
        approval: ClaimedApproval
    ) async -> TransactionApprovalDecision {
        return await withCheckedContinuation { continuation in
            let resolution = TransactionApprovalResolution(
                token: approval.token,
                continuation: continuation
            )
            transactionApprovalResolutions[session.handle] = resolution
            guard transactionSession.approve(
                authenticationMode: authenticationMode
            ) else {
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
        let beginResult = await store.begin(claim: claim)
        let permit: ExtensionBridge.ExecutionPermit
        switch beginResult {
        case .began(let beganPermit):
            permit = beganPermit
        case .ownershipLost:
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
            return
        case .retryablePersistenceFailure:
            await releaseApproval(claim, for: session, token: token)
            return
        }
        switch await operation() {
        case .response(let response):
            await completeExecution(
                permit: permit,
                response: response.markingApprovalCommitted(),
                session: session,
                token: token
            )
        case .broadcast(let prepared):
            switch await store.prepareBroadcast(
                permit: permit,
                recoveryResponse: prepared.recoveryResponse.markingApprovalCommitted()
            ) {
            case .persisted:
                break
            case .ownershipLost:
                if sessions[session.handle] === session {
                    sessions[session.handle] = nil
                }
                return
            case .retryablePersistenceFailure:
                if isCurrent(session, token: token) {
                    session.fail(Strings.failedToLoad, token: token)
                }
                return
            }
            let response = await boundedBroadcast(prepared)
                .markingApprovalCommitted()
            await completeExecution(
                permit: permit,
                response: response,
                session: session,
                token: token
            )
        }
    }

    private func boundedBroadcast(
        _ prepared: PreparedBroadcast
    ) async -> ResponseToExtension {
        return await withCheckedContinuation { continuation in
            let resolution = BroadcastResolution(continuation)
            resolution.sendTask = Task { @MainActor in
                resolution.finish(with: await prepared.send())
            }
            resolution.timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: broadcastTimeoutNanoseconds
                    )
                } catch {
                    return
                }
                resolution.finish(
                    with: prepared.recoveryResponse,
                    cancelSend: true
                )
            }
        }
    }

    private func completeExecution(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension,
        session: PopupRequestSession,
        token: UUID
    ) async {
        switch await store.complete(permit: permit, response: response) {
        case .persisted, .ownershipLost:
            if sessions[session.handle] === session {
                sessions[session.handle] = nil
            }
        case .retryablePersistenceFailure:
            if isCurrent(session, token: token) {
                session.fail(Strings.failedToLoad, token: token)
            }
        }
    }

    private func releaseApproval(
        _ claim: ExtensionBridge.ApprovalClaim,
        for session: PopupRequestSession,
        token: UUID
    ) async {
        switch await store.release(claim: claim) {
        case .persisted:
            if isCurrent(session, token: token) {
                _ = session.returnToReview(token: token)
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
        guard managesWallets else { return }
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
            let authenticationMode = transactionSession.takeAuthenticationMode()
            Task { @MainActor in
                let succeeded = await authenticate(
                    session: session,
                    authenticationMode: authenticationMode,
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
                transactionSession.authenticationCompleted(
                    token: token,
                    succeeded: succeeded && authenticationFinished
                )
                if !succeeded || !authenticationFinished {
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
            finishTransactionApproval(
                resolution,
                for: session,
                with: transaction.map(TransactionApprovalDecision.transaction)
                    ?? .refused
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
