import Foundation
import WalletDomain
import WalletAuthority

public struct NativeMessageDispatcher: Sendable {
    public enum ApprovalPolicy: Equatable, Sendable {
        case native, popup
    }

    public struct ApprovalReference: Sendable {
        public let handle: RequestHandle
        public let configurationKey: String
        public let expectedNonce: NativeDeliveryNonce
        public let isToolbarAction: Bool

        public init(handle: RequestHandle, configurationKey: String, expectedNonce: NativeDeliveryNonce, isToolbarAction: Bool = false) {
            self.handle = handle
            self.configurationKey = configurationKey
            self.expectedNonce = expectedNonce
            self.isToolbarAction = isToolbarAction
        }

        public init(_ snapshot: ExtensionBridge.Snapshot, isToolbarAction: Bool = false) {
            self.init(handle: snapshot.handle, configurationKey: snapshot.configurationKey,
                expectedNonce: snapshot.nativeDeliveryNonce, isToolbarAction: isToolbarAction)
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
            RequestHandle, String, ResponseMaintenance, NativeRequestContext.ResponseAccess
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
            pollResponse: @escaping @Sendable (RequestHandle, String, ResponseMaintenance, NativeRequestContext.ResponseAccess) async -> ExtensionBridge.ResponseReadResult,
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

    private var internalError: ProviderResponseError { .init(message: messages[.somethingWentWrong], code: ProviderResponseError.internalErrorCode) }
    private var userRejected: ProviderResponseError { .init(message: messages[.canceled], code: ProviderResponseError.userRejectedCode) }
    private var privateBrowsingUnsupported: ProviderResponseError { .init(message: messages[.privateBrowsingUnsupported], code: 4200) }

    public func dispatch(message: WireProtocol.JSONObject, context: NativeRequestContext) async throws -> WireProtocol.ValidatedObject {
        try await dispatchMessage(message: message, context: context)
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
            return try await handle(command, request: request, context: context)
        case .popup:
            guard policy == .popup else { throw Error.unsupportedOperation }
            let response = context.privateBrowsing
                ? await dependencies.privatePopup(request)
                : await dependencies.popup(request, context.profileIdentifier)
            guard let object = try? PopupResponseEncoder.encode(response, for: request, messages: messages) else {
                throw Error.invalidMessage
            }
            return object
        }
    }

    private func handle(
        _ command: InternalSafariRequest.WorkerCommand,
        request: InternalSafariRequest,
        context: NativeRequestContext
    ) async throws -> WireProtocol.ValidatedObject {
        let profileIdentifier = context.profileIdentifier
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
                handle, identity.response.configurationKey, identity.maintenance, context.responseAccess
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
        switch ExtensionBridge.admittedIngress(wire: wire, context: context) {
        case .accepted(let value): ingress = value
        case .payloadTooLarge:
            return try response(.init(for: request, error: internalError), for: request)
        case .invalid: throw Error.invalidMessage
        }
        if context.privateBrowsing {
            return try response(.init(for: request, error: privateBrowsingUnsupported), for: request)
        }
        switch await dependencies.bridge.enqueue(
            ingress: ingress,
            profileIdentifier: context.profileIdentifier,
            privateBrowsing: context.privateBrowsing
        ) {
        case .accepted(let handle, let approvalRequired, let authority, let admissionKind, let nativeDeliveryNonce):
            let reference = ApprovalReference(handle: handle, configurationKey: request.configurationKey,
                expectedNonce: nativeDeliveryNonce,
                isToolbarAction: context.source == .worker && request.provider == .unknown && request.name == "switchAccount")
            if !approvalRequired || admissionKind == .coalesced {
                if policy == .native, reference.isToolbarAction {
                    guard await dependencies.reconcile(reference, .admission) == .opened else { throw Error.bridgeUnavailable }
                }
                return try Self.admissionResponse(
                    handle: handle, approvalRequired: approvalRequired,
                    authority: authority, admissionKind: admissionKind
                )
            }
            switch await dependencies.materialize(handle) {
            case .approvalRequired:
                if policy == .native {
                    switch await dependencies.reconcile(
                        reference,
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
                if policy == .native, reference.isToolbarAction {
                    guard await dependencies.reconcile(reference, .admission) == .opened else { throw Error.bridgeUnavailable }
                }
                return try Self.admissionResponse(
                    handle: handle, approvalRequired: false,
                    authority: authority, admissionKind: admissionKind
                )
            case .unavailable: throw Error.bridgeUnavailable
            }
        case .unauthorized(let authority):
            let response = ResponseToExtension(
                for: request, error: .init(message: messages[.providerNotReady], code: 4100)
            )
            return try Self.encode([
                "id": request.id,
                "response": boundedDappResponse(response, for: request).json,
                "state": authority.json,
            ], as: .nativeDelivery)
        case .expired:
            return try response(.init(for: request, error: userRejected), for: request)
        case .manualSwitchCapacityReached:
            return try response(.init(for: request, error: .init(
                message: messages[.manualSwitchCapacityReached],
                code: ProviderResponseError.internalErrorCode
            )), for: request)
        case .rejected:
            return try response(.init(for: request, error: internalError), for: request)
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
            switch await dependencies.bridge.authorizeResponseAccess(
                handle: handle, configurationKey: identity.configurationKey, access: context.responseAccess
            ) {
            case .authorized: break
            case .missing: throw Error.invalidMessage
            case .unavailable: throw Error.bridgeUnavailable
            }
            guard case .found(let snapshot) = await dependencies.bridge.load(handle: handle),
                  snapshot.configurationKey == identity.configurationKey else { throw Error.invalidMessage }
            let isToolbarAction = context.source == .worker && snapshot.isManualSwitch
            switch await dependencies.reconcile(.init(snapshot, isToolbarAction: isToolbarAction), .focus) {
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
            switch await dependencies.bridge.acknowledgeResponse(handle: handle, configurationKey: identity.configurationKey, access: context.responseAccess) {
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

    private func response(_ response: ResponseToExtension, for request: SafariRequest) throws -> WireProtocol.ValidatedObject {
        try boundedDappResponse(response, for: request)
    }

    private func boundedDappResponse(_ response: ResponseToExtension, for request: SafariRequest) throws -> WireProtocol.ValidatedObject {
        let json = response.json
        if ExtensionBridge.isPayloadWithinLimit(json),
           let object = WireProtocol.object(.nativeResponse, value: json) {
            return object
        }
        let fallback = ResponseToExtension(for: request, error: internalError)
        var fallbackJSON = fallback.json
        fallbackJSON["approvalCommitted"] = response.approvalCommitted
        if ExtensionBridge.isPayloadWithinLimit(fallbackJSON) { return try Self.encode(fallbackJSON, as: .nativeResponse) }
        fallbackJSON["name"] = request.provider == .unknown ? "switchAccount" : ""
        fallbackJSON["error"] = [
            "code": ProviderResponseError.internalErrorCode,
            "message": "Failed to process provider response",
        ]
        return try Self.encode(fallbackJSON, as: .nativeResponse)
    }
}
