import Foundation

enum DappAdmissionDisposition: Equatable, Sendable {
    case approvalRequired
    case responseReady
    case unavailable
}

@MainActor
final class DappRequestAdmission {

#if os(iOS) || os(visionOS)
    static let shared = DappRequestAdmission(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor(),
        catalogAccess: { SafariApprovalVault.shared.catalogAccess() }
    )
#else
    static let shared = DappRequestAdmission(
        store: ExtensionBridge.shared,
        requestProcessor: DappRequestProcessor()
    )
#endif

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let catalogAccess: (() -> WalletAccess?)?

    init(
        store: PopupRequestStore,
        requestProcessor: DappRequestProcessing,
        catalogAccess: (() -> WalletAccess?)? = nil
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.catalogAccess = catalogAccess
    }

    func materialize(
        handle: ExtensionBridge.Handle
    ) async -> DappAdmissionDisposition {
        let snapshot: ExtensionBridge.Snapshot
        switch await store.load(handle: handle) {
        case .found(let found):
            snapshot = found
        case .missing, .unavailable:
            return .unavailable
        }
        let request: SafariRequest
        switch snapshot.state {
        case .responded:
            return .responseReady
        case .approving:
            return .approvalRequired
        case .queued(let pendingRequest, .unowned):
            request = pendingRequest
        case .queued:
            return .approvalRequired
        }
        let preparation: DappRequestPreparation
        if let walletIndependent = requestProcessor.prepareWithoutWallets(request) {
            preparation = walletIndependent
        } else if catalogAccess == nil {
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
            )
        } else {
            guard let walletAccess = catalogAccess?() else {
                return await currentAdmissionDisposition(
                    handle: handle,
                    queued: .approvalRequired
                )
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
            switch snapshot.state {
            case .queued(_, .unowned):
                return queued
            case .queued:
                return .approvalRequired
            case .approving:
                return .approvalRequired
            case .responded:
                return .responseReady
            }
        case .missing, .unavailable:
            return .unavailable
        }
    }

}
