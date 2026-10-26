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

public struct NativeMessageDispatcher: Sendable {
    public enum ApprovalPolicy: Equatable, Sendable {
        case native, popup
    }

    public struct ApprovalReference: Sendable {
        public let handle: RequestHandle
        public let configurationKey: String
        public let expectedNonce: NativeDeliveryNonce

        public init(handle: RequestHandle, configurationKey: String, expectedNonce: NativeDeliveryNonce) {
            self.handle = handle
            self.configurationKey = configurationKey
            self.expectedNonce = expectedNonce
        }

        public init(_ snapshot: ExtensionBridge.Snapshot) {
            self.init(handle: snapshot.handle, configurationKey: snapshot.configurationKey, expectedNonce: snapshot.nativeDeliveryNonce)
        }
    }

    public enum ReconciliationIntent: Sendable {
        case admission, focus
    }

    public enum Error: LocalizedError, Equatable {
        case invalidMessage, unsupportedOperation, bridgeUnavailable

        public var errorDescription: String? {
            switch self {
            case .invalidMessage: "Invalid extension message"
            case .unsupportedOperation: "Unsupported extension operation"
            case .bridgeUnavailable: "Big Wallet extension bridge is unavailable"
            }
        }
    }

    public struct Dependencies: Sendable {
        public let bridge: any NativeMessageBridge
        public let materialize: @Sendable (RequestHandle) async -> DappAdmissionDisposition
        public let reconcile: @Sendable (
            ApprovalReference, ReconciliationIntent
            ) async -> NativeApprovalReconciliationResult
        public let pollResponse: @Sendable (
            RequestHandle, String, ResponseMaintenance
        ) async -> ExtensionBridge.ResponseReadResult
        public let rpc: any PublicRPCForwarding
        public let popup: @Sendable (InternalSafariRequest, UUID?) async -> PopupResponse
        public let privatePopup: @Sendable (InternalSafariRequest) async -> PopupResponse
        public let openApp: @Sendable () async -> Bool
        public let invalidateNetworkCache: @Sendable () -> Void

        public init(
            bridge: any NativeMessageBridge,
            materialize: @escaping @Sendable (RequestHandle) async -> DappAdmissionDisposition,
            reconcile: @escaping @Sendable ( ApprovalReference, ReconciliationIntent ) async -> NativeApprovalReconciliationResult,
            pollResponse: @escaping @Sendable (RequestHandle, String, ResponseMaintenance) async -> ExtensionBridge.ResponseReadResult,
            rpc: any PublicRPCForwarding,
            popup: @escaping @Sendable (InternalSafariRequest, UUID?) async -> PopupResponse,
            privatePopup: @escaping @Sendable (InternalSafariRequest) async -> PopupResponse,
            openApp: @escaping @Sendable () async -> Bool,
            invalidateNetworkCache: @escaping @Sendable () -> Void
        ) {
            self.bridge = bridge
            self.materialize = materialize
            self.reconcile = reconcile
            self.pollResponse = pollResponse
            self.rpc = rpc
            self.popup = popup
            self.privatePopup = privatePopup
            self.openApp = openApp
            self.invalidateNetworkCache = invalidateNetworkCache
        }
    }

    private let policy: ApprovalPolicy
    private let dependencies: Dependencies
    private let messages: AuthorityMessages

    public init(policy: ApprovalPolicy, dependencies: Dependencies, messages: AuthorityMessages) {
        self.policy = policy
        self.dependencies = dependencies
        self.messages = messages
    }

    public func dispatch(message: WireProtocol.JSONObject, context: NativeRequestContext) async throws -> WireProtocol.ValidatedObject {
        try await AuthorityMessageContext.$current.withValue(messages) {
            try await dispatchMessage(message: message, context: context)
        }
    }

    private func dispatchMessage(
        message: WireProtocol.JSONObject,
        context: NativeRequestContext
    ) async throws -> WireProtocol.ValidatedObject {
        if message["subject"] != nil {
            return try await handleInternal(
                message: message.json,
                context: context
            )
        }
        return try await handleDapp(
            message: message.json,
            context: context
        )
    }

    private func handleInternal(
        message: [String: Any],
        context: NativeRequestContext
    ) async throws -> WireProtocol.ValidatedObject {
        guard let wire = WireProtocol.object(.nativeCommand, value: message),
              let request = try? InternalSafariRequest(wire: wire),
              context.authorizes(request)
        else { throw Error.invalidMessage }
        switch request.command {
        case .page(.rpc): break
        default:
            guard let data = ExtensionBridge.payloadData(message),
                  ExtensionBridge.isInternalPayloadAllowed(command: request.command, byteCount: data.count)
            else { throw Error.invalidMessage }
        }
        switch request.command {
        case .openApp:
            guard policy == .native else { throw Error.unsupportedOperation }
            guard await dependencies.openApp() else { throw Error.bridgeUnavailable }
            return try Self.encode(["id": request.id, "opened": true], as: .nativeOpenReply)
        case .page(let command):
            guard !context.privateBrowsing else { throw Error.unsupportedOperation }
            return try await handle(command, request: request, context: context)
        case .worker(let command):
            guard !context.privateBrowsing else { throw Error.unsupportedOperation }
            return try await handle(command, request: request, profileIdentifier: context.profileIdentifier)
        case .popup:
            guard policy == .popup else { throw Error.unsupportedOperation }
            let response = context.privateBrowsing
                ? await dependencies.privatePopup(request)
                : await dependencies.popup(request, context.profileIdentifier)
            guard let object = try? PopupResponseEncoder.encode(response, for: request) else {
                throw Error.invalidMessage
            }
            return object
        }
    }

    private func handle(
        _ command: InternalSafariRequest.WorkerCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?
    ) async throws -> WireProtocol.ValidatedObject {
        switch command {
        case .getRecoveryRequests:
            switch await dependencies.bridge.listRecoveryRequests(profileIdentifier: profileIdentifier) {
            case .available(let requests):
                return try Self.encode(["id": request.id, "requests": requests.map(\.json)], as: .nativeRecoveryReply)
            case .unavailable:
                return try Self.status(.unavailable, id: request.id)
            }
        case .pollResponse(let identity):
            let handle = RequestHandle(
                id: request.id, token: identity.response.token, profileIdentifier: profileIdentifier
            )
            let result = await dependencies.pollResponse(
                handle, identity.response.configurationKey, identity.maintenance
            )
            let response: [String: Any]
            switch result {
            case .response(let delivery):
                if let terminal = delivery["response"] as? [String: Any],
                   ResponseToExtension(json: terminal)?.addsEthereumChain == true {
                    dependencies.invalidateNetworkCache()
                }
                response = delivery.json
            case .pending: response = ["id": request.id, "pending": true]
            case .missing: response = ["id": request.id, "missing": true]
            case .unavailable: response = ["id": request.id, "unavailable": true]
            }
            return try Self.encode(response, as: .nativeResponsePollReply)
        }
    }

    private func handleDapp(
        message: [String: Any],
        context: NativeRequestContext
    ) async throws -> WireProtocol.ValidatedObject {
        guard let wire = WireProtocol.object(.dappRequest, value: message),
              let request = SafariRequest(wire: wire),
              context.authorizes(request) else { throw Error.invalidMessage }
        let ingress: ExtensionBridge.Ingress
        switch ExtensionBridge.dappIngressResult(request: request, wire: wire) {
        case .accepted(let value): ingress = value
        case .payloadTooLarge:
            return try Self.response(.init(for: request, payload: .error(.internalError)), for: request)
        case .invalid: throw Error.invalidMessage
        }
        if context.privateBrowsing {
            return try Self.response(.init(for: request, payload: .error(.privateBrowsingUnsupported)), for: request)
        }
        switch await dependencies.bridge.enqueue(
            ingress: ingress,
            profileIdentifier: context.profileIdentifier,
            privateBrowsing: context.privateBrowsing
        ) {
        case .accepted(let handle, let approvalRequired, let authority, let admissionKind, let nativeDeliveryNonce):
            if !approvalRequired || admissionKind == .coalesced {
                return try Self.admissionResponse(
                    handle: handle, approvalRequired: approvalRequired,
                    authority: authority, admissionKind: admissionKind
                )
            }
            switch await dependencies.materialize(handle) {
            case .approvalRequired:
                if policy == .native {
                    switch await dependencies.reconcile(
                        .init(handle: handle, configurationKey: request.configurationKey, expectedNonce: nativeDeliveryNonce),
                        .admission
                    ) {
                    case .pending, .opened: break
                    case .responseReady:
                        return try Self.admissionResponse(
                            handle: handle, approvalRequired: false,
                            authority: authority, admissionKind: admissionKind
                        )
                    case .missing, .unavailable: throw Error.bridgeUnavailable
                    }
                }
                return try Self.admissionResponse(
                    handle: handle, approvalRequired: true,
                    authority: authority, admissionKind: admissionKind
                )
            case .responseReady:
                return try Self.admissionResponse(
                    handle: handle, approvalRequired: false,
                    authority: authority, admissionKind: admissionKind
                )
            case .unavailable: throw Error.bridgeUnavailable
            }
        case .unauthorized(let authority):
            let response = ResponseToExtension(
                for: request, payload: .error(.init(message: AuthorityStrings.providerNotReady, code: 4100))
            )
            return try Self.encode([
                "id": request.id,
                "response": Self.boundedDappResponse(response, for: request).json,
                "state": authority.json,
            ], as: .nativeDelivery)
        case .expired:
            return try Self.response(.init(for: request, payload: .error(.userRejected)), for: request)
        case .manualSwitchCapacityReached:
            return try Self.response(.init(for: request, payload: .error(.init(
                message: AuthorityStrings.manualSwitchCapacityReached,
                code: ProviderResponseError.internalErrorCode
            ))), for: request)
        case .rejected:
            return try Self.response(.init(for: request, payload: .error(.internalError)), for: request)
        case .unavailable:
            throw Error.bridgeUnavailable
        }
    }

    private func handle(
        _ command: InternalSafariRequest.PageCommand,
        request: InternalSafariRequest,
        context: NativeRequestContext
    ) async throws -> WireProtocol.ValidatedObject {
        let profileIdentifier = context.profileIdentifier
        switch command {
        case .getLatestConfiguration(let configurationKey):
            switch await dependencies.bridge.configurationSnapshot(
                configurationKey: configurationKey, profileIdentifier: profileIdentifier
            ) {
            case .snapshot(let snapshot):
                return try Self.encode(["id": request.id, "state": snapshot.json], as: .nativeConfigurationReply)
            case .unavailable:
                return try Self.status(.unavailable, id: request.id)
            }
        case .disconnect(let identity):
            switch await dependencies.bridge.revoke(
                configurationKey: identity.configurationKey,
                provider: identity.provider,
                attempt: identity.attempt,
                expected: identity.authority,
                profileIdentifier: profileIdentifier
            ) {
            case .revoked(let snapshot):
                return try Self.encode(["id": request.id, "state": snapshot.json, "revoked": true], as: .nativeDisconnectReply)
            case .stale(let snapshot):
                return try Self.encode(["id": request.id, "state": snapshot.json, "stale": true], as: .nativeDisconnectReply)
            case .unavailable:
                return try Self.status(.unavailable, id: request.id)
            }
        case .rpc(let body, let chainId):
            guard case .site(let site, _) = context.source else { throw Error.invalidMessage }
            return try await rpcRequest(
                id: request.id, chainId: chainId, body: body,
                scope: .init(profileIdentifier: profileIdentifier, origin: site.configurationKey)
            )
        case .showApproval(let identity):
            guard policy == .native else { throw Error.unsupportedOperation }
            let handle = RequestHandle(id: request.id, token: identity.token, profileIdentifier: profileIdentifier)
            guard case .found(let snapshot) = await dependencies.bridge.load(handle: handle),
                  snapshot.configurationKey == identity.configurationKey else { throw Error.invalidMessage }
            switch await dependencies.reconcile(.init(snapshot), .focus) {
            case .opened:
                return try Self.encode(["id": request.id, "opened": true], as: .nativeOpenReply)
            case .pending:
                return try Self.status(.pending, id: request.id)
            case .responseReady:
                return try Self.status(.ready, id: request.id)
            case .missing, .unavailable:
                return try Self.encode(["id": request.id, "opened": false], as: .nativeOpenReply)
            }
        case .acknowledgeResponse(let identity):
            let handle = RequestHandle(id: request.id, token: identity.token, profileIdentifier: profileIdentifier)
            switch await dependencies.bridge.acknowledgeResponse(handle: handle, configurationKey: identity.configurationKey) {
            case .persisted:
                return try Self.encode(["id": request.id, "acknowledged": true], as: .nativeAcknowledgementReply)
            case .ownershipLost:
                return try Self.status(.missing, id: request.id)
            case .retryablePersistenceFailure:
                throw Error.bridgeUnavailable
            }
        }
    }

    private func rpcRequest(
        id: Int, chainId: String, body: String, scope: RPCScope
    ) async throws -> WireProtocol.ValidatedObject {
        await dependencies.rpc.forward(id: id, chainId: chainId, body: body, scope: scope).wire
    }
    private static func admissionResponse(
        handle: RequestHandle,
        approvalRequired: Bool,
        authority: RequestAuthoritySnapshot,
        admissionKind: ExtensionBridge.AdmissionKind
    ) throws -> WireProtocol.ValidatedObject {
        let kind: String
        switch admissionKind {
        case .new: kind = "new"
        case .replay: kind = "replay"
        case .coalesced: kind = "coalesced"
        }
        return try encode([
            "id": handle.id, "requestToken": handle.requestToken,
            "approvalRequired": approvalRequired, "admissionKind": kind,
            "state": authority.json,
        ], as: .nativeEnqueueAcknowledgement)
    }

    private static func status(
        _ status: ExtensionBridge.ResponseStatusResult,
        id: Int
    ) throws -> WireProtocol.ValidatedObject {
        let key: String
        switch status {
        case .pending: key = "pending"
        case .ready: key = "ready"
        case .missing: key = "missing"
        case .unavailable: key = "unavailable"
        }
        return try encode(["id": id, key: true], as: .nativeStatus)
    }

    private static func encode(_ response: [String: Any], as contract: WireProtocol.Message) throws -> WireProtocol.ValidatedObject {
        guard let object = WireProtocol.object(contract, value: response) else { throw Error.invalidMessage }
        return object
    }

    private static func response(_ response: ResponseToExtension, for request: SafariRequest) throws -> WireProtocol.ValidatedObject {
        try boundedDappResponse(response, for: request)
    }

    private static func boundedDappResponse(_ response: ResponseToExtension, for request: SafariRequest) throws -> WireProtocol.ValidatedObject {
        let json = response.json
        if ExtensionBridge.isPayloadWithinLimit(json),
           let object = WireProtocol.object(.nativeResponse, value: json) {
            return object
        }
        var fallback = ResponseToExtension(for: request, payload: .error(.internalError))
        if response.approvalCommitted { fallback = fallback.markingApprovalCommitted() }
        var internalError = fallback.json
        if ExtensionBridge.isPayloadWithinLimit(internalError) { return try encode(internalError, as: .nativeResponse) }
        internalError["name"] = request.provider == .unknown ? "switchAccount" : ""
        internalError["error"] = [
            "code": ProviderResponseError.internalErrorCode,
            "message": "Failed to process provider response",
        ]
        return try encode(internalError, as: .nativeResponse)
    }
}
