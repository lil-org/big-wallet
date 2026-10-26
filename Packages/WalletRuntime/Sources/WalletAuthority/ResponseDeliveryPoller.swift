import WalletDomain
import Foundation

public struct ResponseDeliveryPoller: Sendable {
    private let responseStatus: @Sendable (
        RequestHandle, String
    ) async -> ExtensionBridge.ResponseStatusResult
    private let maintain: @Sendable (
        RequestHandle, String, ResponseMaintenance
    ) async -> ExtensionBridge.ResponseStatusResult
    private let prepareDelivery: @Sendable (
        RequestHandle, String
    ) async -> ExtensionBridge.ResponseReadResult

    public init(
        responseStatus: @escaping @Sendable (
            RequestHandle, String
        ) async -> ExtensionBridge.ResponseStatusResult,
        maintain: @escaping @Sendable (
            RequestHandle, String, ResponseMaintenance
        ) async -> ExtensionBridge.ResponseStatusResult,
        prepareDelivery: @escaping @Sendable (
            RequestHandle, String
        ) async -> ExtensionBridge.ResponseReadResult
    ) {
        self.responseStatus = responseStatus
        self.maintain = maintain
        self.prepareDelivery = prepareDelivery
    }

    public func poll(
        handle: RequestHandle,
        configurationKey: String,
        maintenance: ResponseMaintenance
    ) async -> ExtensionBridge.ResponseReadResult {
        guard !Task.isCancelled else { return .unavailable }
        let status = maintenance == .none
            ? await responseStatus(handle, configurationKey)
            : await maintain(handle, configurationKey, maintenance)
        guard !Task.isCancelled else { return .unavailable }
        switch status {
        case .pending: return .pending
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .ready:
            let delivery = await prepareDelivery(handle, configurationKey)
            return Task.isCancelled ? .unavailable : delivery
        }
    }
}
