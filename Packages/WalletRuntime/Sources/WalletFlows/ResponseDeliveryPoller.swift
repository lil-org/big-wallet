import WalletAuthority
import WalletDomain
import Foundation

public struct ResponseDeliveryPoller: Sendable {
    private let authorize: @Sendable (
        RequestHandle, String, NativeRequestContext.ResponseAccess
    ) async -> ExtensionBridge.ResponseAccessResult
    private let responseStatus: @Sendable (
        RequestHandle, String, NativeRequestContext.ResponseAccess
    ) async -> ExtensionBridge.ResponseStatusResult
    private let maintain: @Sendable (
        RequestHandle, String, ResponseMaintenance, NativeRequestContext.ResponseAccess
    ) async -> ExtensionBridge.ResponseStatusResult
    private let prepareDelivery: @Sendable (
        RequestHandle, String, NativeRequestContext.ResponseAccess
    ) async -> ExtensionBridge.ResponseReadResult

    public init(
        authorize: @escaping @Sendable (
            RequestHandle, String, NativeRequestContext.ResponseAccess
        ) async -> ExtensionBridge.ResponseAccessResult,
        responseStatus: @escaping @Sendable (
            RequestHandle, String, NativeRequestContext.ResponseAccess
        ) async -> ExtensionBridge.ResponseStatusResult,
        maintain: @escaping @Sendable (
            RequestHandle, String, ResponseMaintenance, NativeRequestContext.ResponseAccess
        ) async -> ExtensionBridge.ResponseStatusResult,
        prepareDelivery: @escaping @Sendable (
            RequestHandle, String, NativeRequestContext.ResponseAccess
        ) async -> ExtensionBridge.ResponseReadResult
    ) {
        self.authorize = authorize
        self.responseStatus = responseStatus
        self.maintain = maintain
        self.prepareDelivery = prepareDelivery
    }

    public func poll(
        handle: RequestHandle,
        configurationKey: String,
        maintenance: ResponseMaintenance,
        access: NativeRequestContext.ResponseAccess
    ) async -> ExtensionBridge.ResponseReadResult {
        guard !Task.isCancelled else { return .unavailable }
        let status: ExtensionBridge.ResponseStatusResult
        if maintenance == .none {
            status = await responseStatus(handle, configurationKey, access)
        } else {
            switch await authorize(handle, configurationKey, access) {
            case .authorized: break
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
            guard !Task.isCancelled else { return .unavailable }
            status = await maintain(handle, configurationKey, maintenance, access)
        }
        guard !Task.isCancelled else { return .unavailable }
        switch status {
        case .pending: return .pending
        case .missing: return .missing
        case .unavailable: return .unavailable
        case .ready:
            let delivery = await prepareDelivery(handle, configurationKey, access)
            return Task.isCancelled ? .unavailable : delivery
        }
    }
}
