import Foundation

public struct TransactionApprovalOperations: Sendable {
    public typealias Prepare =
        @MainActor (Transaction, Bool, EthereumNetwork) -> AsyncThrowingStream<TransactionPreparationEvent, Error>
    public typealias Preflight = @MainActor @Sendable (Transaction, EthereumNetwork) async throws -> TransactionFeePreflightResult

    public let prepare: Prepare
    public let preflight: Preflight

    public nonisolated init(prepare: @escaping Prepare, preflight: @escaping Preflight) {
        self.prepare = prepare
        self.preflight = preflight
    }

}

