// ∅ 2026 lil org

import Foundation

protocol NativeMessageBridge: Sendable {
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
        expected: ExtensionBridge.AuthorityVersion,
        profileIdentifier: UUID?
    ) async -> ExtensionBridge.AuthorityMutationResult
    func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult
    func acknowledgeResponse(handle: ExtensionBridge.Handle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult
}

extension ExtensionBridge: NativeMessageBridge {}

struct NativeMessageDispatcher: Sendable {
    enum ApprovalPolicy: Equatable, Sendable {
        case native, popup
    }

    struct ApprovalReference: Sendable {
        let handle: ExtensionBridge.Handle
        let configurationKey: String
        let expectedNonce: ExtensionBridge.NativeDeliveryNonce

        init(handle: ExtensionBridge.Handle, configurationKey: String, expectedNonce: ExtensionBridge.NativeDeliveryNonce) {
            self.handle = handle
            self.configurationKey = configurationKey
            self.expectedNonce = expectedNonce
        }

        init(_ snapshot: ExtensionBridge.Snapshot) {
            self.init(handle: snapshot.handle, configurationKey: snapshot.configurationKey, expectedNonce: snapshot.nativeDeliveryNonce)
        }
    }

    enum ReconciliationIntent: Sendable {
        case admission, focus
    }

    enum ReconciliationResult: Sendable {
        case pending, responseReady, opened, missing, unavailable
    }

    enum Error: LocalizedError, Equatable {
        case invalidMessage, unsupportedOperation, bridgeUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidMessage: "Invalid extension message"
            case .unsupportedOperation: "Unsupported extension operation"
            case .bridgeUnavailable: "Big Wallet extension bridge is unavailable"
            }
        }
    }

    struct Dependencies: Sendable {
        let bridge: any NativeMessageBridge
        let materialize: @Sendable (ExtensionBridge.Handle) async -> DappAdmissionDisposition
        let reconcile: @Sendable (
            ApprovalReference, ReconciliationIntent
        ) async -> ReconciliationResult
        let pollResponse: @Sendable (
            ExtensionBridge.Handle, String, ResponseDeliveryPoller.Maintenance
        ) async -> ExtensionBridge.ResponseReadResult
        let rpcNetwork: @Sendable (Int) -> ResolvedEthereumNetwork?
        let sendRPC: @Sendable (EthereumRPCEndpoint, Data, Int) async throws -> WireProtocol.JSONObject
        let popup: @Sendable (InternalSafariRequest, UUID?) async -> PopupResponse
        let privatePopup: @Sendable (InternalSafariRequest) async -> PopupResponse
        let openApp: @Sendable () async -> Bool
        let invalidateNetworkCache: @Sendable () -> Void
    }

    private static let genericRPCFailureMessage = "something went wrong"
    private let policy: ApprovalPolicy
    private let dependencies: Dependencies

    init(policy: ApprovalPolicy, dependencies: Dependencies) {
        self.policy = policy
        self.dependencies = dependencies
    }

    func dispatch(
        message: WireProtocol.JSONObject,
        profileIdentifier: UUID?,
        privateBrowsing: Bool
    ) async throws -> WireProtocol.ValidatedObject {
        if message["subject"] != nil {
            return try await handleInternal(
                message: message.json,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing
            )
        }
        return try await handleDapp(
            message: message.json,
            profileIdentifier: profileIdentifier,
            privateBrowsing: privateBrowsing
        )
    }

    private func handleInternal(
        message: [String: Any],
        profileIdentifier: UUID?,
        privateBrowsing: Bool
    ) async throws -> WireProtocol.ValidatedObject {
        guard let wire = WireProtocol.object(.nativeCommand, value: message),
              let request = try? InternalSafariRequest(wire: wire),
              let data = ExtensionBridge.payloadData(message),
              ExtensionBridge.isInternalPayloadAllowed(command: request.command, byteCount: data.count)
        else { throw Error.invalidMessage }
        switch request.command {
        case .openApp:
            guard policy == .native else { throw Error.unsupportedOperation }
            guard await dependencies.openApp() else { throw Error.bridgeUnavailable }
            return try Self.encode(["id": request.id, "opened": true], as: .nativeOpenReply)
        case .page(let command):
            guard !privateBrowsing else { throw Error.unsupportedOperation }
            return try await handle(command, request: request, profileIdentifier: profileIdentifier)
        case .worker(let command):
            guard !privateBrowsing else { throw Error.unsupportedOperation }
            return try await handle(command, request: request, profileIdentifier: profileIdentifier)
        case .popup:
            guard policy == .popup else { throw Error.unsupportedOperation }
            let response = privateBrowsing
                ? await dependencies.privatePopup(request)
                : await dependencies.popup(request, profileIdentifier)
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
            let handle = ExtensionBridge.Handle(
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
        profileIdentifier: UUID?,
        privateBrowsing: Bool
    ) async throws -> WireProtocol.ValidatedObject {
        guard let wire = WireProtocol.object(.dappRequest, value: message),
              let request = SafariRequest(wire: wire) else { throw Error.invalidMessage }
        let ingress: ExtensionBridge.Ingress
        switch ExtensionBridge.dappIngressResult(request: request, wire: wire) {
        case .accepted(let value): ingress = value
        case .payloadTooLarge:
            return try Self.response(.init(for: request, payload: .error(.internalError)), for: request)
        case .invalid: throw Error.invalidMessage
        }
        if privateBrowsing {
            return try Self.response(.init(for: request, payload: .error(.privateBrowsingUnsupported)), for: request)
        }
        switch await dependencies.bridge.enqueue(
            ingress: ingress,
            profileIdentifier: profileIdentifier,
            privateBrowsing: privateBrowsing
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
                for: request, payload: .error(.init(message: Strings.providerNotReady, code: 4100))
            )
            return try Self.encode([
                "id": request.id,
                "response": Self.boundedDappResponse(response, for: request),
                "state": authority.json,
            ], as: .nativeDelivery)
        case .expired:
            return try Self.response(.init(for: request, payload: .error(.userRejected)), for: request)
        case .manualSwitchCapacityReached:
            return try Self.response(.init(for: request, payload: .error(.init(
                message: Strings.manualSwitchCapacityReached,
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
        profileIdentifier: UUID?
    ) async throws -> WireProtocol.ValidatedObject {
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
            return try await rpcRequest(id: request.id, chainId: chainId, body: body)
        case .showApproval(let identity):
            guard policy == .native else { throw Error.unsupportedOperation }
            let handle = ExtensionBridge.Handle(id: request.id, token: identity.token, profileIdentifier: profileIdentifier)
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
            let handle = ExtensionBridge.Handle(id: request.id, token: identity.token, profileIdentifier: profileIdentifier)
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

    private func rpcRequest(id: Int, chainId: String, body: String) async throws -> WireProtocol.ValidatedObject {
        guard let chainIdNumber = Int(hexString: chainId),
              let resolvedNetwork = dependencies.rpcNetwork(chainIdNumber),
              let httpBody = body.data(using: .utf8) else {
            return try Self.encode(["id": id, "error": Self.genericRPCFailureMessage], as: .rpcResponse)
        }
        do {
            let response = try await dependencies.sendRPC(resolvedNetwork.rpcEndpoint, httpBody, id)
            guard let projected = RPCResponseToExtension(upstream: response.json, expectedResponseID: id) else {
                throw Error.invalidMessage
            }
            return try Self.encode(projected.json, as: .rpcResponse)
        } catch {
            return try Self.encode(["id": id, "error": Self.genericRPCFailureMessage], as: .rpcResponse)
        }
    }

    private static func admissionResponse(
        handle: ExtensionBridge.Handle,
        approvalRequired: Bool,
        authority: ExtensionBridge.AuthoritySnapshot,
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
        try encode(boundedDappResponse(response, for: request), as: .nativeResponse)
    }

    private static func boundedDappResponse(_ response: ResponseToExtension, for request: SafariRequest) -> [String: Any] {
        let json = response.json
        if ExtensionBridge.isPayloadWithinLimit(json), WireProtocol.validate(.nativeResponse, value: json) {
            return json
        }
        var fallback = ResponseToExtension(for: request, payload: .error(.internalError))
        if response.approvalCommitted { fallback = fallback.markingApprovalCommitted() }
        var internalError = fallback.json
        if ExtensionBridge.isPayloadWithinLimit(internalError) { return internalError }
        internalError["name"] = request.provider == .unknown ? "switchAccount" : ""
        internalError["error"] = [
            "code": ProviderResponseError.internalErrorCode,
            "message": "Failed to process provider response",
        ]
        return internalError
    }
}
