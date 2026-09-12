// ∅ 2026 lil org

import Foundation

struct ApprovalRouteKey: Hashable {
    let handle: ExtensionBridge.Handle
    let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
}

@MainActor
struct ApprovalInbox<ActiveApproval> {
    private struct Entry {
        let coordinator: NativeApprovalCoordinator
        let registrationIndex: Int
        var value: ActiveApproval?

        var key: ApprovalRouteKey {
            ApprovalRouteKey(
                handle: coordinator.handle,
                nativeDeliveryNonce: coordinator.nativeDeliveryNonce
            )
        }
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

    var coordinators: [NativeApprovalCoordinator] {
        entries.map(\.coordinator)
    }

    var hasAwaitingAuthentication: Bool {
        entries.contains { $0.coordinator.state == .awaitingAuthentication }
    }

    mutating func register(_ coordinator: NativeApprovalCoordinator) -> Bool {
        let key = ApprovalRouteKey(
            handle: coordinator.handle,
            nativeDeliveryNonce: coordinator.nativeDeliveryNonce
        )
        guard index(for: key) == nil,
              entries.filter({ $0.coordinator.countsTowardUnverifiedLimit }).count <
                maximumUnverifiedCount else { return false }
        entries.append(Entry(
            coordinator: coordinator,
            registrationIndex: nextRegistrationIndex
        ))
        nextRegistrationIndex += 1
        return true
    }

    func coordinator(for key: ApprovalRouteKey) -> NativeApprovalCoordinator? {
        guard let index = index(for: key) else { return nil }
        return entries[index].coordinator
    }

    @discardableResult
    mutating func activate(
        _ value: ActiveApproval,
        for key: ApprovalRouteKey
    ) -> Bool {
        guard let index = index(for: key),
              entries[index].coordinator.state == .awaitingAuthentication,
              entries[index].value == nil else { return false }
        entries[index].value = value
        return true
    }

    func active(for key: ApprovalRouteKey) -> ActiveApproval? {
        guard let index = index(for: key) else { return nil }
        return entries[index].value
    }

    func oldestActive(
        where predicate: (ActiveApproval) -> Bool
    ) -> (key: ApprovalRouteKey, value: ActiveApproval)? {
        entries.sorted(by: precedes).compactMap { entry in
            guard let value = entry.value, predicate(value) else { return nil }
            return (entry.key, value)
        }.first
    }

    var awaitingAuthenticationKeys: [ApprovalRouteKey] {
        entries.filter {
            $0.coordinator.state == .awaitingAuthentication
        }.sorted(by: precedes).map(\.key)
    }

    mutating func remove(_ key: ApprovalRouteKey) {
        guard let index = index(for: key) else { return }
        entries.remove(at: index)
    }

    private func index(for key: ApprovalRouteKey) -> Int? {
        entries.firstIndex { $0.key == key }
    }

    private func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.coordinator.order, rhs.coordinator.order) {
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
