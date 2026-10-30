import WalletDomain
import WalletStorageSupport
import Foundation

public enum DappAdmissionDisposition: Equatable, Sendable {
    case approvalRequired
    case responseReady
    case unavailable
}

@MainActor
public final class DappRequestAdmission {

    private let store: PopupRequestStore
    private let requestProcessor: DappRequestProcessing
    private let reviewCatalog: (() -> WalletReviewCatalog?)?
    private let messages: AuthorityMessages

    init(
        store: PopupRequestStore,
        requestProcessor: DappRequestProcessing,
        reviewCatalog: (() -> WalletReviewCatalog?)? = nil,
        messages: AuthorityMessages = .testingEnglish
    ) {
        self.store = store
        self.requestProcessor = requestProcessor
        self.reviewCatalog = reviewCatalog
        self.messages = messages
    }

    public func materialize(
        handle: RequestHandle
    ) async -> DappAdmissionDisposition {
        await AuthorityMessageContext.$current.withValue(messages) {
            await materializeScoped(handle: handle)
        }
    }

    private func materializeScoped(handle: RequestHandle) async -> DappAdmissionDisposition {
        let snapshot: ExtensionBridge.Snapshot
        switch await store.load(handle: handle) {
        case .found(let found):
            snapshot = found
        case .missing, .unavailable:
            return .unavailable
        }
        switch snapshot.state {
        case .responded:
            return .responseReady
        case .approving:
            return .approvalRequired
        case .queued(_, .unowned):
            break
        case .queued:
            return .approvalRequired
        }
        guard let binding = snapshot.requestBinding else { return .unavailable }
        guard await store.authorityIsCurrent(handle: handle) else { return .unavailable }
        let preparation: DappRequestPreparation
        let prepared = await requestProcessor.prepare(binding, loadingCatalog: { reviewCatalog?() })
        guard !Task.isCancelled else { return .unavailable }
        switch prepared {
        case .catalogUnavailable:
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
            )
        case .prepared(let result, _):
            preparation = result
        }
        switch preparation {
        case .needsCatalog, .approval, .unavailable:
            return await currentAdmissionDisposition(
                handle: handle,
                queued: .approvalRequired
            )
        case .immediate(let response):
            switch await store.completeImmediate(handle: handle, resolution: response) {
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
        handle: RequestHandle,
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

