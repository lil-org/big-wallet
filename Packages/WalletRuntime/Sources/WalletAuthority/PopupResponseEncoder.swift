import Foundation
import WalletDomain

enum PopupResponseEncoder: Sendable {
    static let maximumResponseBytes = WireProtocol.maximumPopupResponseBytes

    static func encode(_ response: PopupResponse, for request: InternalSafariRequest) throws -> WireProtocol.ValidatedObject {
        let encoder = JSONEncoder()
        if let object = bounded(response, using: encoder) { return object }
        if let object = bounded(response.removingDecorativeImages, using: encoder) { return object }
        guard case .popup(let command) = request.command,
              returnsApprovalState(command) else {
            return try validated(PopupResponse.queueUnavailable, using: encoder)
        }
        let original = response.approvalState
        guard case .command(let command) = response else {
            return try validated(PopupResponse.queueUnavailable, using: encoder)
        }
        var fallback = PopupApprovalState(
            id: request.id,
            host: original?.host,
            content: .error(
                message: AuthorityStrings.somethingWentWrong,
                actions: original?.canReject == true ? [.reject] : [.retry]
            )
        )
        if let object = bounded(.command(command.replacingApprovalState(fallback)), using: encoder) { return object }
        fallback.host = nil
        return try validated(PopupResponse.command(command.replacingApprovalState(fallback)), using: encoder)
    }

    private static func bounded(_ response: PopupResponse, using encoder: JSONEncoder) -> WireProtocol.ValidatedObject? {
        guard let data = try? encoder.encode(response),
              data.count <= maximumResponseBytes,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return WireProtocol.object(.popupResponse, value: json)
    }

    private static func validated(_ response: PopupResponse, using encoder: JSONEncoder) throws -> WireProtocol.ValidatedObject {
        guard let object = bounded(response, using: encoder) else {
            throw EncodingError.invalidValue(response, .init(
                codingPath: [], debugDescription: "Invalid or oversized popup response"
            ))
        }
        return object
    }

    private static func returnsApprovalState(_ command: InternalSafariRequest.PopupCommand) -> Bool {
        switch command {
        case .getApprovalState, .retryApproval, .applyTransactionEdits,
             .retryTransaction, .setTransactionSpeed, .approveRequest,
             .rejectRequest:
            return true
        case .getPendingRequests:
            return false
        }
    }
}
