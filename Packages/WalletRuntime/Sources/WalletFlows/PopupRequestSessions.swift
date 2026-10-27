import Foundation
import WalletDomain
import WalletAuthority

@MainActor
public final class PopupRequestSessions {
    private let authority: PopupApprovalAuthority
    private let presenter: PopupApprovalStatePresenter
    private let messages: AuthorityMessages

    public init(authority: PopupApprovalAuthority, presentation: PopupApprovalStatePresenter.Environment, messages: AuthorityMessages) {
        self.authority = authority
        presenter = PopupApprovalStatePresenter(environment: presentation, messages: messages)
        self.messages = messages
    }

    public func privateBrowsingResponse(for request: InternalSafariRequest) -> PopupResponse {
        guard case .popup(.getPendingRequests) = request.command else {
            return .command(.init(status: .ignored, approvalState: nil))
        }
        return .queue(presenter.pendingResponse())
    }

    public func dispatch(request: InternalSafariRequest, profileIdentifier: UUID?) async -> PopupResponse {
        let response = await authority.dispatch(request: request, profileIdentifier: profileIdentifier)
        return render(response)
    }

    private func render(_ response: PopupAuthorityResponse) -> PopupResponse {
        switch response {
        case .queue(let pending, let completed):
            return .queue(presenter.pendingResponse(requests: pending.map(presenter.pendingRequest),
                completedResponses: completed.map(presenter.completedResponse)))
        case .queueUnavailable: return .queueUnavailable
        case .command(let status, let state):
            let presentation = state.map {
                presenter.state(id: $0.id, host: $0.host, presentation: $0.content,
                    transactionMutationAllowed: $0.transactionMutationAllowed)
            }
            return .command(.init(status: status, approvalState: presentation))
        }
    }
}
