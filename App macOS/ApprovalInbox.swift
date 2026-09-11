// ∅ 2026 lil org

import Foundation

struct ApprovalRouteKey: Hashable {
    let handle: ExtensionBridge.Handle
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
}

@MainActor
struct ApprovalInbox<ActiveApproval> {
    struct Order: Equatable {
        let createdAt: Date
        let sequence: Int
    }

    struct Cancellation: Equatable {
        let key: ApprovalRouteKey
        let receiptOwned: Bool
    }

    enum ReceiptAcquisitionDisposition: Equatable {
        case awaitAuthentication
        case cancel
    }

    enum Phase {
        case validating(started: Bool)
        case acquiringReceipt(cancelRequested: Bool)
        case awaitingAuthentication
        case active(ActiveApproval)
        case canceling(receiptOwned: Bool)
    }

    private struct Entry {
        let key: ApprovalRouteKey
        var order: Order?
        let registrationIndex: Int
        var phase: Phase
    }

    let maximumUnverifiedCount: Int
    private var entries = [Entry]()
    private var nextRegistrationIndex = 0

    init(
        maximumUnverifiedCount: Int =
            ExtensionBridge.maximumGlobalRetainedRequests
    ) {
        self.maximumUnverifiedCount = maximumUnverifiedCount
    }

    var count: Int { entries.count }

    var hasAwaitingAuthentication: Bool {
        entries.contains {
            if case .awaitingAuthentication = $0.phase { return true }
            return false
        }
    }

    mutating func register(_ key: ApprovalRouteKey) -> Bool {
        guard index(for: key) == nil,
              unverifiedCount < maximumUnverifiedCount else { return false }
        entries.append(Entry(
            key: key,
            order: nil,
            registrationIndex: nextRegistrationIndex,
            phase: .validating(started: false)
        ))
        nextRegistrationIndex += 1
        return true
    }

    private var unverifiedCount: Int {
        entries.reduce(into: 0) { count, entry in
            switch entry.phase {
            case .validating, .acquiringReceipt,
                 .canceling(receiptOwned: false):
                count += 1
            case .awaitingAuthentication, .active,
                 .canceling(receiptOwned: true):
                break
            }
        }
    }

    mutating func takeUnstartedValidations() -> [ApprovalRouteKey] {
        var result = [ApprovalRouteKey]()
        for index in entries.indices {
            guard case .validating(started: false) = entries[index].phase else {
                continue
            }
            entries[index].phase = .validating(started: true)
            result.append(entries[index].key)
        }
        return result
    }

    func isValidating(_ key: ApprovalRouteKey) -> Bool {
        guard let entry = entry(for: key), case .validating = entry.phase else {
            return false
        }
        return true
    }

    mutating func beginReceiptAcquisition(
        _ key: ApprovalRouteKey,
        order: Order
    ) -> Bool {
        guard let index = index(for: key),
              case .validating = entries[index].phase else {
            return false
        }
        entries[index].order = order
        entries[index].phase = .acquiringReceipt(cancelRequested: false)
        return true
    }

    mutating func receiptAcquired(
        _ key: ApprovalRouteKey
    ) -> ReceiptAcquisitionDisposition? {
        guard let index = index(for: key),
              case .acquiringReceipt(let cancelRequested) =
                entries[index].phase else {
            return nil
        }
        if cancelRequested {
            entries[index].phase = .canceling(receiptOwned: true)
            return .cancel
        }
        entries[index].phase = .awaitingAuthentication
        return .awaitAuthentication
    }

    func isAcquiringReceipt(_ key: ApprovalRouteKey) -> Bool {
        guard let entry = entry(for: key),
              case .acquiringReceipt = entry.phase else {
            return false
        }
        return true
    }

    func isAwaitingAuthentication(_ key: ApprovalRouteKey) -> Bool {
        guard let entry = entry(for: key),
              case .awaitingAuthentication = entry.phase else {
            return false
        }
        return true
    }

    @discardableResult
    mutating func activate(
        _ value: ActiveApproval,
        for key: ApprovalRouteKey
    ) -> Bool {
        guard let index = index(for: key) else { return false }
        switch entries[index].phase {
        case .awaitingAuthentication:
            entries[index].phase = .active(value)
            return true
        case .validating, .acquiringReceipt, .active, .canceling:
            return false
        }
    }

    func active(for key: ApprovalRouteKey) -> ActiveApproval? {
        guard let entry = entry(for: key),
              case .active(let value) = entry.phase else {
            return nil
        }
        return value
    }

    func oldestActive(
        where predicate: (ActiveApproval) -> Bool
    ) -> (key: ApprovalRouteKey, value: ActiveApproval)? {
        entries.compactMap { entry -> Entry? in
            guard case .active(let value) = entry.phase,
                  predicate(value) else { return nil }
            return entry
        }.sorted(by: precedes).compactMap { entry in
            guard case .active(let value) = entry.phase else { return nil }
            return (entry.key, value)
        }.first
    }

    mutating func markPendingAsCanceling() -> [Cancellation] {
        var result = [Cancellation]()
        for index in entries.indices {
            switch entries[index].phase {
            case .validating:
                entries[index].phase = .canceling(receiptOwned: false)
                result.append(Cancellation(
                    key: entries[index].key,
                    receiptOwned: false
                ))
            case .acquiringReceipt:
                entries[index].phase = .acquiringReceipt(cancelRequested: true)
            case .awaitingAuthentication:
                entries[index].phase = .canceling(receiptOwned: true)
                result.append(Cancellation(
                    key: entries[index].key,
                    receiptOwned: true
                ))
            case .active, .canceling:
                break
            }
        }
        return result
    }

    @discardableResult
    mutating func markOwnedAsCanceling(
        _ key: ApprovalRouteKey
    ) -> Bool {
        guard let index = index(for: key) else { return false }
        switch entries[index].phase {
        case .awaitingAuthentication:
            entries[index].phase = .canceling(receiptOwned: true)
            return true
        case .validating, .acquiringReceipt, .active, .canceling:
            return false
        }
    }

    func isCanceling(_ key: ApprovalRouteKey) -> Bool {
        guard let entry = entry(for: key), case .canceling = entry.phase else {
            return false
        }
        return true
    }

    @discardableResult
    mutating func restoreAwaitingAuthentication(
        _ key: ApprovalRouteKey
    ) -> Bool {
        guard let index = index(for: key),
              case .canceling(receiptOwned: true) = entries[index].phase else {
            return false
        }
        entries[index].phase = .awaitingAuthentication
        return true
    }

    var awaitingAuthenticationKeys: [ApprovalRouteKey] {
        entries.compactMap { entry -> Entry? in
            guard case .awaitingAuthentication = entry.phase else {
                return nil
            }
            return entry
        }.sorted(by: precedes).map { entry in
            entry.key
        }
    }

    mutating func remove(_ key: ApprovalRouteKey) {
        guard let index = index(for: key) else { return }
        entries.remove(at: index)
    }

    private func index(for key: ApprovalRouteKey) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    private func entry(for key: ApprovalRouteKey) -> Entry? {
        guard let index = index(for: key) else { return nil }
        return entries[index]
    }

    private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.order, rhs.order) {
        case (.some(let lhsOrder), .some(let rhsOrder)):
            if lhsOrder.createdAt != rhsOrder.createdAt {
                return lhsOrder.createdAt < rhsOrder.createdAt
            }
            if lhsOrder.sequence != rhsOrder.sequence {
                return lhsOrder.sequence < rhsOrder.sequence
            }
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            break
        }
        return lhs.registrationIndex < rhs.registrationIndex
    }
}
