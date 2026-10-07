// ∅ 2026 lil org

import SafariServices

let SFExtensionMessageKey = "message"

private enum HandlerError: LocalizedError {
    case invalidMessage
    case unsupportedOperation
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Invalid extension message"
        case .unsupportedOperation:
            return "Unsupported extension operation"
        case .bridgeUnavailable:
            return "Big Wallet extension bridge is unavailable"
        }
    }
}

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let rpcClient = SafariRPCClient()
    private static let bridge = ExtensionBridge.shared
    private static let genericRPCFailureMessage = "something went wrong"
#if os(macOS)
    @MainActor private static let nativeApprovalService = NativeApprovalService.live
#endif
    private static let responsePoller = ResponseDeliveryPoller(
        responseStatus: { handle, configurationKey in
            await bridge.responseStatus(handle: handle, configurationKey: configurationKey)
        },
        maintain: { handle, configurationKey, maintenance in
#if os(macOS)
            let result = await nativeApprovalService.reconcile(
                .init(handle: handle, configurationKey: configurationKey),
                intent: .maintenance(allowDelivery: maintenance == .interactive)
            )
            switch result {
            case .pending, .opened: return .pending
            case .responseReady: return .ready
            case .missing: return .missing
            case .unavailable: return .unavailable
            }
#else
            await bridge.performMaintenance(profileIdentifier: handle.profileIdentifier)
            return await bridge.responseStatus(handle: handle, configurationKey: configurationKey)
#endif
        },
        prepareDelivery: { handle, configurationKey in
            await bridge.prepareResponseDelivery(
                id: handle.id,
                configurationKey: configurationKey,
                requestToken: handle.token.rawValue,
                profileIdentifier: handle.profileIdentifier
            )
        }
    )

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              var json = WireProtocol.JSONObject(message)?.json else {
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        let privateBrowsing: Bool
        switch ExtensionBridge.takePrivateBrowsing(from: &json) {
        case .value(let value):
            privateBrowsing = value
        case .missing, .malformed:
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        let profileIdentifier = item.userInfo?[SFExtensionProfileKey] as? UUID
        // Foundation's borrowed context is handed exclusively to one terminal responder.
        nonisolated(unsafe) let transferredContext = context
        let responder = ExtensionRequestResponder(context: transferredContext)
        if json["subject"] != nil {
            handleInternal(
                message: json,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: responder
            )
        } else {
            handleDapp(
                message: json,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: responder
            )
        }
    }

    private func handleInternal(
        message: [String: Any],
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: ExtensionRequestResponder
    ) {
        guard let wire = WireProtocol.object(.nativeCommand, value: message),
              let request = try? InternalSafariRequest(wire: wire),
              let data = ExtensionBridge.payloadData(message),
              ExtensionBridge.isInternalPayloadAllowed(
                  command: request.command,
                  byteCount: data.count
              ) else {
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        switch request.command {
        case .openApp:
#if os(macOS)
            openNativeAgent(id: request.id, context: context)
#else
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
#endif
        case .page(let command):
            handle(
                command,
                request: request,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: context
            )
        case .worker(let command):
            handle(
                command,
                request: request,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: context
            )
        case .popup:
#if os(macOS)
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
#else
            Task { @MainActor in
                let response: PopupResponse
                if privateBrowsing {
                    response = await PopupRequestSessions.dispatchPrivateBrowsing(
                        request: request
                    )
                } else {
                    response = await PopupRequestSessions.dispatch(
                        request: request,
                        profileIdentifier: profileIdentifier
                    )
                }
                guard let object = try? PopupResponseEncoder.encode(response, for: request) else {
                    context.cancelRequest(withError: HandlerError.invalidMessage)
                    return
                }
                Self.respond(with: object, context: context)
            }
#endif
        }
    }

    private func handle(
        _ command: InternalSafariRequest.WorkerCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: ExtensionRequestResponder
    ) {
        guard !privateBrowsing else {
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
            return
        }
        switch command {
        case .getRecoveryRequests:
            Task {
                switch await Self.bridge.listRecoveryRequests(profileIdentifier: profileIdentifier) {
                case .available(let requests):
                    Self.respond(with: [
                        "id": request.id,
                        "requests": requests.map(\.json),
                    ], contract: .nativeRecoveryReply, context: context)
                case .unavailable:
                    Self.respond(with: ["id": request.id, "unavailable": true], contract: .nativeStatus, context: context)
                }
            }
        case .pollResponse(let identity):
            Task {
                let handle = ExtensionBridge.Handle(
                    id: request.id, token: identity.response.token, profileIdentifier: profileIdentifier
                )
                let result = await Self.responsePoller.poll(
                    handle: handle,
                    configurationKey: identity.response.configurationKey,
                    maintenance: identity.maintenance
                )
                Self.respondPoll(result, id: request.id, context: context)
            }
        }
    }

    private func handleDapp(
        message: [String: Any],
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: ExtensionRequestResponder
    ) {
        guard let wire = WireProtocol.object(.dappRequest, value: message),
              let request = SafariRequest(wire: wire) else {
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        let ingress: ExtensionBridge.Ingress
        switch ExtensionBridge.dappIngressResult(
            request: request,
            wire: wire
        ) {
        case .accepted(let acceptedIngress):
            ingress = acceptedIngress
        case .payloadTooLarge:
            Self.respond(
                with: ResponseToExtension(for: request, payload: .error(.internalError)),
                for: request,
                context: context
            )
            return
        case .invalid:
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        if privateBrowsing {
            Self.respond(
                with: ResponseToExtension(
                    for: request,
                    payload: .error(.privateBrowsingUnsupported)
                ),
                for: request,
                context: context
            )
            return
        }
        Task {
            switch await Self.bridge.enqueue(
                ingress: ingress,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing
            ) {
            case .accepted(
                let handle,
                let approvalRequired,
                let authority,
                let admissionKind,
                let nativeDeliveryNonce
            ):
                if !approvalRequired || admissionKind == .coalesced {
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: approvalRequired,
                            authority: authority,
                            admissionKind: admissionKind
                        ),
                        contract: .nativeEnqueueAcknowledgement,
                        context: context
                    )
                    return
                }
                switch await DappRequestAdmission.shared.materialize(handle: handle) {
                case .approvalRequired:
#if os(macOS)
                    switch await Self.nativeApprovalService.reconcile(
                        .init(
                            handle: handle,
                            configurationKey: request.configurationKey,
                            expectedNonce: nativeDeliveryNonce
                        ),
                        intent: .admission
                    ) {
                    case .pending, .opened:
                        break
                    case .responseReady:
                        Self.respond(
                            with: Self.admissionResponse(
                                handle: handle, approvalRequired: false, authority: authority,
                                admissionKind: admissionKind
                            ),
                            contract: .nativeEnqueueAcknowledgement,
                            context: context
                        )
                        return
                    case .missing, .unavailable:
                        context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                        return
                    }
#endif
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: true,
                            authority: authority,
                            admissionKind: admissionKind
                        ),
                        contract: .nativeEnqueueAcknowledgement,
                        context: context
                    )
                case .responseReady:
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: false,
                            authority: authority,
                            admissionKind: admissionKind
                        ),
                        contract: .nativeEnqueueAcknowledgement,
                        context: context
                    )
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            case .unauthorized(let authority):
                let response = ResponseToExtension(
                    for: request,
                    payload: .error(.init(message: Strings.providerNotReady, code: 4100))
                )
                Self.respond(with: [
                    "id": request.id,
                    "response": Self.boundedDappResponse(response, for: request),
                    "state": authority.json,
                ], contract: .nativeDelivery, context: context)
            case .expired:
                Self.respond(
                    with: ResponseToExtension(
                        for: request,
                        payload: .error(.userRejected)
                    ),
                    for: request,
                    context: context
                )
            case .manualSwitchCapacityReached:
                Self.respond(
                    with: ResponseToExtension(for: request, payload: .error(.init(
                        message: Strings.manualSwitchCapacityReached,
                        code: ProviderResponseError.internalErrorCode
                    ))),
                    for: request,
                    context: context
                )
            case .rejected:
                Self.respond(
                    with: ResponseToExtension(for: request, payload: .error(.internalError)),
                    for: request,
                    context: context
                )
            case .unavailable:
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
            }
        }
    }

    private static func admissionResponse(
        handle: ExtensionBridge.Handle,
        approvalRequired: Bool,
        authority: ExtensionBridge.AuthoritySnapshot,
        admissionKind: ExtensionBridge.AdmissionKind
    ) -> [String: Any] {
        let kind: String
        switch admissionKind {
        case .new: kind = "new"
        case .replay: kind = "replay"
        case .coalesced: kind = "coalesced"
        }
        return [
            "id": handle.id,
            "requestToken": handle.requestToken,
            "approvalRequired": approvalRequired,
            "admissionKind": kind,
            "state": authority.json,
        ]
    }

    private func handle(
        _ command: InternalSafariRequest.PageCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: ExtensionRequestResponder
    ) {
        guard !privateBrowsing else {
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
            return
        }
        switch command {
        case .getLatestConfiguration(let configurationKey):
            Task {
                switch await Self.bridge.configurationSnapshot(
                    configurationKey: configurationKey,
                    profileIdentifier: profileIdentifier
                ) {
                case .snapshot(let snapshot):
                    Self.respond(with: ["id": request.id, "state": snapshot.json], contract: .nativeConfigurationReply, context: context)
                case .unavailable:
                    Self.respond(with: ["id": request.id, "unavailable": true], contract: .nativeStatus, context: context)
                }
            }
        case .disconnect(let identity):
            Task {
                switch await Self.bridge.revoke(
                    configurationKey: identity.configurationKey,
                    provider: identity.provider,
                    attempt: identity.attempt,
                    expected: identity.authority,
                    profileIdentifier: profileIdentifier
                ) {
                case .revoked(let snapshot):
                    Self.respond(with: [
                        "id": request.id, "state": snapshot.json, "revoked": true,
                    ], contract: .nativeDisconnectReply, context: context)
                case .stale(let snapshot):
                    Self.respond(with: [
                        "id": request.id, "state": snapshot.json, "stale": true,
                    ], contract: .nativeDisconnectReply, context: context)
                case .unavailable:
                    Self.respond(with: ["id": request.id, "unavailable": true], contract: .nativeStatus, context: context)
                }
            }
        case .rpc(let body, let chainId):
            rpcRequest(
                id: request.id,
                chainId: chainId,
                body: body,
                context: context
            )
        case .showApproval(let identity):
#if os(macOS)
            guard !privateBrowsing else {
                context.cancelRequest(withError: HandlerError.unsupportedOperation)
                return
            }
            Task { @MainActor in
                let handle = ExtensionBridge.Handle(
                    id: request.id,
                    token: identity.token,
                    profileIdentifier: profileIdentifier
                )
                guard case .found(let snapshot) = await Self.bridge.load(handle: handle),
                      snapshot.configurationKey == identity.configurationKey else {
                    context.cancelRequest(withError: HandlerError.invalidMessage)
                    return
                }
                let result = await Self.nativeApprovalService.reconcile(
                    .init(snapshot), intent: .focus
                )
                switch result {
                case .opened:
                    Self.respond(with: ["id": request.id, "opened": true], contract: .nativeOpenReply, context: context)
                case .pending:
                    Self.respondStatus(.pending, id: request.id, context: context)
                case .responseReady:
                    Self.respondStatus(.ready, id: request.id, context: context)
                case .missing, .unavailable:
                    Self.respond(with: ["id": request.id, "opened": false], contract: .nativeOpenReply, context: context)
                }
            }
#else
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
#endif
        case .acknowledgeResponse(let identity):
            guard !privateBrowsing else {
                context.cancelRequest(withError: HandlerError.unsupportedOperation)
                return
            }
            Task {
                let handle = ExtensionBridge.Handle(
                    id: request.id,
                    token: identity.token,
                    profileIdentifier: profileIdentifier
                )
                switch await Self.bridge.acknowledgeResponse(
                    handle: handle,
                    configurationKey: identity.configurationKey
                ) {
                case .persisted:
                    Self.respond(with: [
                        "id": request.id,
                        "acknowledged": true,
                    ], contract: .nativeAcknowledgementReply, context: context)
                case .ownershipLost:
                    Self.respond(with: [
                        "id": request.id,
                        "missing": true,
                    ], contract: .nativeStatus, context: context)
                case .retryablePersistenceFailure:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            }
        }
    }

    private static func respondPoll(
        _ result: ExtensionBridge.ResponseReadResult,
        id: Int,
        context: ExtensionRequestResponder
    ) {
        let response: [String: Any]
        switch result {
        case .response(let delivery):
            if let terminal = delivery["response"] as? [String: Any],
               ResponseToExtension(json: terminal)?.addsEthereumChain == true {
                CustomNetworkCache.shared.invalidate()
            }
            response = delivery.json
        case .pending: response = ["id": id, "pending": true]
        case .missing: response = ["id": id, "missing": true]
        case .unavailable: response = ["id": id, "unavailable": true]
        }
        respond(with: response, contract: .nativeResponsePollReply, context: context)
    }

    private static func respondStatus(
        _ status: ExtensionBridge.ResponseStatusResult,
        id: Int,
        context: ExtensionRequestResponder
    ) {
        let key: String
        switch status {
        case .pending: key = "pending"
        case .ready: key = "ready"
        case .missing: key = "missing"
        case .unavailable: key = "unavailable"
        }
        respond(with: ["id": id, key: true], contract: .nativeStatus, context: context)
    }

    private func rpcRequest(
        id: Int,
        chainId: String,
        body: String,
        context: ExtensionRequestResponder
    ) {
        guard let chainIdNumber = Int(hexString: chainId),
              let resolvedNetwork = Nodes.resolution(chainId: chainIdNumber).resolvedNetwork,
              let httpBody = body.data(using: .utf8) else {
            Self.respond(with: ["id": id, "error": Self.genericRPCFailureMessage], contract: .rpcResponse, context: context)
            return
        }
        Task {
            do {
                let response = try await Self.rpcClient.send(
                    endpoint: resolvedNetwork.rpcEndpoint,
                    body: httpBody,
                    expectedResponseID: id
                )
                guard let projected = RPCResponseToExtension(upstream: response.json, expectedResponseID: id) else {
                    throw SafariRPCClient.Error.invalidResponse
                }
                Self.respond(with: projected.json, contract: .rpcResponse, context: context)
            } catch {
                Self.respond(
                    with: ["id": id, "error": Self.genericRPCFailureMessage],
                    contract: .rpcResponse,
                    context: context
                )
            }
        }
    }
    
    private static func respond(
        with response: [String: Any],
        contract: WireProtocol.Message,
        context: ExtensionRequestResponder
    ) {
        guard let object = WireProtocol.object(contract, value: response) else {
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        respond(with: object, context: context)
    }

    private static func respond(
        with response: WireProtocol.ValidatedObject,
        context: ExtensionRequestResponder
    ) {
        context.complete(with: response)
    }

    private static func respond(
        with response: ResponseToExtension,
        for request: SafariRequest,
        context: ExtensionRequestResponder
    ) {
        respond(with: boundedDappResponse(response, for: request), contract: .nativeResponse, context: context)
    }

    private static func boundedDappResponse(
        _ response: ResponseToExtension,
        for request: SafariRequest
    ) -> [String: Any] {
        let json = response.json
        if ExtensionBridge.isPayloadWithinLimit(json),
           WireProtocol.validate(.nativeResponse, value: json) {
            return json
        }
        var fallback = ResponseToExtension(for: request, payload: .error(.internalError))
        if response.approvalCommitted { fallback = fallback.markingApprovalCommitted() }
        var internalError = fallback.json
        if ExtensionBridge.isPayloadWithinLimit(internalError) {
            return internalError
        }
        internalError["name"] = request.provider == .unknown ? "switchAccount" : ""
        internalError["error"] = [
            "code": ProviderResponseError.internalErrorCode,
            "message": "Failed to process provider response",
        ]
        return internalError
    }

#if os(macOS)
    private func openNativeAgent(id: Int, context: ExtensionRequestResponder) {
        Task {
            let opened = await Self.nativeApprovalService.openWallet()
            guard opened else {
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                return
            }
            Self.respond(with: ["id": id, "opened": true], contract: .nativeOpenReply, context: context)
        }
    }

#endif
    
}
