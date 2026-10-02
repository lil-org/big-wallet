import Foundation

struct ResponseDeliveryPoller {
    enum Maintenance: String, Sendable {
        case none, quiet, interactive
    }

    private let responseStatus: (
        ExtensionBridge.Handle, String
    ) async -> ExtensionBridge.ResponseStatusResult
    private let maintain: (
        ExtensionBridge.Handle, String, Maintenance
    ) async -> ExtensionBridge.ResponseStatusResult
    private let prepareDelivery: (
        ExtensionBridge.Handle, String
    ) async -> ExtensionBridge.ResponseReadResult

    init(
        responseStatus: @escaping (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.ResponseStatusResult,
        maintain: @escaping (
            ExtensionBridge.Handle, String, Maintenance
        ) async -> ExtensionBridge.ResponseStatusResult,
        prepareDelivery: @escaping (
            ExtensionBridge.Handle, String
        ) async -> ExtensionBridge.ResponseReadResult
    ) {
        self.responseStatus = responseStatus
        self.maintain = maintain
        self.prepareDelivery = prepareDelivery
    }

    func poll(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        maintenance: Maintenance
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
