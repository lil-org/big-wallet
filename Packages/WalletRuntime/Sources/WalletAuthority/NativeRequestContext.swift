import WalletDomain
// ∅ 2026 lil org

import Foundation

public struct NativeRequestContext: Sendable {
    public struct SiteIdentity: Equatable, Sendable {
        public let host: String
        public let configurationKey: String

        public init(
            host: String,
            configurationKey: String
        ) {
            self.host = host
            self.configurationKey = configurationKey
        }
    }

    public struct DocumentIdentity: Equatable, Sendable {
        public let tabID: Int
        public let frameID: Int
        public let documentID: String?

        public init(
            tabID: Int,
            frameID: Int,
            documentID: String?
        ) {
            self.tabID = tabID
            self.frameID = frameID
            self.documentID = documentID
        }
    }

    public enum Source: Equatable, Sendable {
        case site(SiteIdentity, DocumentIdentity)
        case popup
        case worker
    }

    public let source: Source
    public let privateBrowsing: Bool
    public let profileIdentifier: UUID?

    private init?(_ wire: WireProtocol.ValidatedObject, profileIdentifier: UUID?) {
        guard wire.contract == .nativeTransportContext,
              let source = wire.json["source"] as? String,
              let privateBrowsing = wire.json["privateBrowsing"] as? Bool else { return nil }
        switch source {
        case "site":
            guard let site = wire.json["site"] as? [String: Any],
                  let host = site["host"] as? String,
                  let configurationKey = site["configurationKey"] as? String,
                  ExtensionBridge.isValidIdentity(host: host, configurationKey: configurationKey),
                  let document = wire.json["document"] as? [String: Any],
                  let tabID = document["tabId"] as? Int,
                  let frameID = document["frameId"] as? Int else { return nil }
            self.source = .site(
                SiteIdentity(host: host, configurationKey: configurationKey),
                DocumentIdentity(tabID: tabID, frameID: frameID, documentID: document["documentId"] as? String)
            )
        case "popup":
            self.source = .popup
        case "worker":
            self.source = .worker
        default:
            return nil
        }
        self.privateBrowsing = privateBrowsing
        self.profileIdentifier = profileIdentifier
    }

    public static func extract(
        from message: Any,
        profileIdentifier: UUID?
    ) -> (message: WireProtocol.JSONObject, context: NativeRequestContext)? {
        guard var json = WireProtocol.JSONObject(message)?.json,
              let rawContext = json.removeValue(forKey: WireProtocol.nativeContextKey),
              let wire = WireProtocol.object(.nativeTransportContext, value: rawContext),
              let context = NativeRequestContext(wire, profileIdentifier: profileIdentifier),
              let payload = WireProtocol.JSONObject(json) else { return nil }
        return (payload, context)
    }

    public func authorizes(_ request: SafariRequest) -> Bool {
        switch source {
        case .site(let site, _):
            return request.host == site.host && request.configurationKey == site.configurationKey
        case .popup:
            return false
        case .worker:
            guard case .unknown(let body) = request.body else { return false }
            return body.method == .switchAccount
        }
    }

    public func authorizes(_ request: InternalSafariRequest) -> Bool {
        switch request.command {
        case .openApp:
            return source == .worker
        case .popup:
            return source == .popup
        case .worker(.getRecoveryRequests):
            return source == .worker
        case .worker(.pollResponse(let identity)):
            return matches(configurationKey: identity.response.configurationKey)
        case .page(let command):
            switch command {
            case .rpc:
                if case .site = source { return true }
                return false
            case .getLatestConfiguration(let configurationKey):
                return matches(configurationKey: configurationKey)
            case .disconnect(let identity):
                guard case .site = source else { return false }
                return matches(configurationKey: identity.configurationKey)
            case .acknowledgeResponse(let identity):
                return matches(configurationKey: identity.configurationKey)
            case .showApproval(let identity):
                return source != .popup && matches(configurationKey: identity.configurationKey)
            }
        }
    }

    private func matches(configurationKey: String) -> Bool {
        guard case .site(let site, _) = source else { return true }
        return site.configurationKey == configurationKey
    }
}

public enum NativeApprovalReconciliationResult: Equatable, Sendable {
    case pending, responseReady, opened, missing, unavailable
}

public protocol NativeMessageBridge: Sendable {
    func enqueue(
        ingress: ExtensionBridge.Ingress,
        profileIdentifier: UUID?,
        privateBrowsing: Bool
    ) async -> ExtensionBridge.EnqueueResult
    func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityReadResult
    func revoke(
        configurationKey: String,
        provider: InpageProvider,
        attempt: String,
        expected: RequestAuthorityVersion,
        profileIdentifier: UUID?
    ) async -> ExtensionBridge.AuthorityMutationResult
    func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult
    func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult
    func acknowledgeResponse(handle: RequestHandle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: NativeMessageBridge {}

