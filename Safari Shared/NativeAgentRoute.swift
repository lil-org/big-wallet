// ∅ 2026 lil org

import Foundation

enum NativeAgentRoute: Equatable, Sendable {
    case approval(
        workflowVersion: Int,
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
    )
    case showWallet(workflowVersion: Int)

    private static let scheme = "bigwallet"
    private static let host = "agent"

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme,
              components.host == Self.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let items = components.queryItems,
              Set(items.map(\.name)).count == items.count else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        guard let workflowRaw = values["workflowVersion"] ?? nil,
              let workflowVersion = Int(workflowRaw),
              String(workflowVersion) == workflowRaw,
              workflowVersion == ExtensionBridge.workflowVersion else { return nil }
        switch components.path {
        case "/approval":
            let required = Set([
                "workflowVersion",
                "id",
                "requestToken",
                "nativeDeliveryNonce",
            ])
            let allowed = required.union(["profileIdentifier"])
            guard Set(values.keys).isSubset(of: allowed),
                  required.isSubset(of: Set(values.keys)),
                  let idRaw = values["id"] ?? nil,
                  let id = Int(idRaw),
                  String(id) == idRaw,
                  let requestToken = values["requestToken"] ?? nil,
                  let nativeDeliveryNonceRaw = values[
                    "nativeDeliveryNonce"
                  ] ?? nil,
                  let nativeDeliveryNonce = ExtensionBridge.NativeDeliveryNonce(
                    rawValue: nativeDeliveryNonceRaw
                  ) else { return nil }
            let profileIdentifier: UUID?
            if let rawProfile = values["profileIdentifier"] ?? nil {
                guard let profile = ExtensionBridge.lowercaseUUID(rawProfile) else {
                    return nil
                }
                profileIdentifier = profile
            } else {
                profileIdentifier = nil
            }
            guard let handle = ExtensionBridge.Handle(
                id: id,
                requestToken: requestToken,
                profileIdentifier: profileIdentifier
            ) else { return nil }
            self = .approval(
                workflowVersion: workflowVersion,
                handle: handle,
                nativeDeliveryNonce: nativeDeliveryNonce
            )
        case "/wallet":
            guard Set(values.keys) == Set(["workflowVersion"]) else { return nil }
            self = .showWallet(workflowVersion: workflowVersion)
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        switch self {
        case .approval(
            let workflowVersion,
            let handle,
            let nativeDeliveryNonce
        ):
            components.path = "/approval"
            var items = [
                URLQueryItem(name: "workflowVersion", value: String(workflowVersion)),
                URLQueryItem(name: "id", value: String(handle.id)),
                URLQueryItem(name: "requestToken", value: handle.requestToken),
                URLQueryItem(
                    name: "nativeDeliveryNonce",
                    value: nativeDeliveryNonce.rawValue
                ),
            ]
            if let profileIdentifier = handle.profileIdentifier {
                items.append(URLQueryItem(
                    name: "profileIdentifier",
                    value: profileIdentifier.uuidString.lowercased()
                ))
            }
            components.queryItems = items
        case .showWallet(let workflowVersion):
            components.path = "/wallet"
            components.queryItems = [URLQueryItem(
                name: "workflowVersion",
                value: String(workflowVersion)
            )]
        }
        return components.url!
    }
}
