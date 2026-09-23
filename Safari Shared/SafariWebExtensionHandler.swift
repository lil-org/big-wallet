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

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              var json = message as? [String: Any] else {
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
        if json["subject"] != nil {
            guard JSONSerialization.isValidJSONObject(json),
                  let data = try? JSONSerialization.data(withJSONObject: json) else {
                context.cancelRequest(withError: HandlerError.invalidMessage)
                return
            }
            handleInternal(
                data: data,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: context
            )
        } else {
            handleDapp(
                message: json,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                context: context
            )
        }
    }

    private func handleInternal(
        data: Data,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: NSExtensionContext
    ) {
        guard let request = try? JSONDecoder().decode(InternalSafariRequest.self, from: data),
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
                guard let data = try? PopupResponseEncoder.encode(response, for: request),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    context.cancelRequest(withError: HandlerError.invalidMessage)
                    return
                }
                Self.respond(with: json, context: context)
            }
#endif
        }
    }

    private func handle(
        _ command: InternalSafariRequest.WorkerCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: NSExtensionContext
    ) {
        guard !privateBrowsing else {
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
            return
        }
        switch command {
        case .getManualSwitchRequests:
            Task {
                switch await Self.bridge.listManualSwitchRequests(
                    profileIdentifier: profileIdentifier
                ) {
                case .available(let requests):
                    Self.respond(with: [
                        "id": request.id,
                        "requests": requests.map(\.json),
                    ], context: context)
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            }
        case .getManualSwitchResponse(let identity):
            readResponseStatus(
                id: request.id, identity: identity, profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing, manualOnly: true, context: context
            )
        case .getExecutionStatus(let identity):
            Task {
                let handle = ExtensionBridge.Handle(
                    id: request.id, token: identity.token, profileIdentifier: profileIdentifier
                )
                switch await Self.bridge.executionStatus(
                    handle: handle, configurationKey: identity.configurationKey
                ) {
                case .status(let state):
                    Self.respond(with: ["id": request.id, "state": state.rawValue], context: context)
                case .missing:
                    Self.respond(with: ["id": request.id, "missing": true], context: context)
                case .unavailable:
                    Self.respond(with: ["id": request.id, "unavailable": true], context: context)
                }
            }
        case .executeNativeApproval(let execution):
            Task {
#if os(macOS)
                let handle = ExtensionBridge.Handle(
                    id: request.id, token: execution.response.token,
                    profileIdentifier: profileIdentifier
                )
                let status = await Self.nativeApprovalService.executeNativeApproval(
                    handle: handle,
                    configurationKey: execution.response.configurationKey,
                    attemptID: execution.attemptID,
                    revisions: execution.revisions,
                    executionDeadline: execution.executionDeadline
                )
#else
                let status = ExtensionBridge.ResponseStatusResult.unavailable
#endif
                Self.respondStatus(status, id: request.id, context: context)
            }
        case .maintainRequest(let identity):
            Task {
                let handle = ExtensionBridge.Handle(
                    id: request.id, token: identity.response.token, profileIdentifier: profileIdentifier
                )
#if os(macOS)
                let status = await Self.nativeApprovalService.maintainRequest(
                    handle: handle, configurationKey: identity.response.configurationKey,
                    allowDelivery: identity.allowDelivery
                )
#else
                await Self.bridge.performMaintenance(profileIdentifier: profileIdentifier)
                let status = await Self.bridge.responseStatus(
                    handle: handle, configurationKey: identity.response.configurationKey
                )
#endif
                Self.respondStatus(status, id: request.id, context: context)
            }
        case .prepareResponseDelivery(let identity):
            Task {
                let result = await Self.bridge.prepareResponseDelivery(
                    id: request.id,
                    configurationKey: identity.configurationKey,
                    requestToken: identity.token.rawValue,
                    profileIdentifier: profileIdentifier
                )
                switch result {
                case .response(let response):
                    if ResponseToExtension(json: response)?.addsEthereumChain == true {
                        CustomNetworkCache.shared.invalidate()
                    }
                    Self.respond(with: response, context: context)
                case .pending:
                    Self.respondStatus(.pending, id: request.id, context: context)
                case .missing:
                    Self.respondStatus(.missing, id: request.id, context: context)
                case .unavailable:
                    Self.respondStatus(.unavailable, id: request.id, context: context)
                }
            }
        }
    }

    private func handleDapp(
        message: [String: Any],
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: NSExtensionContext
    ) {
        guard let request = SafariRequest(json: message) else {
            context.cancelRequest(withError: HandlerError.invalidMessage)
            return
        }
        let ingress: ExtensionBridge.Ingress
        switch ExtensionBridge.dappIngressResult(
            request: request,
            rawObject: message
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
                let revisions,
                let admissionKind,
                let nativeDeliveryNonce
            ):
                if ingress.replayOnly || !approvalRequired || admissionKind == .coalesced {
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: approvalRequired,
                            revisions: revisions
                        ),
                        context: context
                    )
                    return
                }
                switch await DappRequestAdmission.shared.materialize(handle: handle) {
                case .approvalRequired:
#if os(macOS)
                    switch await Self.nativeApprovalService.deliverApproval(
                        handle: handle, nativeDeliveryNonce: nativeDeliveryNonce
                    ) {
                    case .pending:
                        break
                    case .responseReady:
                        Self.respond(
                            with: Self.admissionResponse(
                                handle: handle, approvalRequired: false, revisions: revisions
                            ),
                            context: context
                        )
                        return
                    case .unavailable:
                        context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                        return
                    }
#endif
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: true,
                            revisions: revisions
                        ),
                        context: context
                    )
                case .responseReady:
                    Self.respond(
                        with: Self.admissionResponse(
                            handle: handle,
                            approvalRequired: false,
                            revisions: revisions
                        ),
                        context: context
                    )
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
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
        revisions: ExtensionBridge.ProviderRevisions
    ) -> [String: Any] {
        return [
            "id": handle.id,
            "requestToken": handle.requestToken,
            "approvalRequired": approvalRequired,
            "revisions": revisions.json,
        ]
    }

    private func handle(
        _ command: InternalSafariRequest.PageCommand,
        request: InternalSafariRequest,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        context: NSExtensionContext
    ) {
        switch command {
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
                let opened = await Self.nativeApprovalService.reactivate(.approval(
                    workflowVersion: ExtensionBridge.workflowVersion,
                    handle: handle,
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                ))
                Self.respond(with: ["id": request.id, "opened": opened], context: context)
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
                    ], context: context)
                case .ownershipLost:
                    Self.respond(with: [
                        "id": request.id,
                        "missing": true,
                    ], context: context)
                case .retryablePersistenceFailure:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            }
        case .getResponse(let identity):
            readResponseStatus(
                id: request.id, identity: identity, profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing, manualOnly: false, context: context
            )
        }
    }

    private func readResponseStatus(
        id: Int,
        identity: InternalSafariRequest.ResponseIdentity,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        manualOnly: Bool,
        context: NSExtensionContext
    ) {
        guard !privateBrowsing else {
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
            return
        }
        Task {
            let handle = ExtensionBridge.Handle(
                id: id, token: identity.token, profileIdentifier: profileIdentifier
            )
            let status = await Self.bridge.responseStatus(
                handle: handle, configurationKey: identity.configurationKey,
                manualOnly: manualOnly
            )
            Self.respondStatus(status, id: id, context: context)
        }
    }

    private static func respondStatus(
        _ status: ExtensionBridge.ResponseStatusResult,
        id: Int,
        context: NSExtensionContext
    ) {
        let key: String
        switch status {
        case .pending: key = "pending"
        case .ready: key = "ready"
        case .missing: key = "missing"
        case .unavailable: key = "unavailable"
        }
        respond(with: ["id": id, key: true], context: context)
    }

    private func rpcRequest(
        id: Int,
        chainId: String,
        body: String,
        context: NSExtensionContext
    ) {
        guard let chainIdNumber = Int(hexString: chainId),
              let resolvedNetwork = Nodes.resolution(chainId: chainIdNumber).resolvedNetwork,
              let httpBody = body.data(using: .utf8) else {
            Self.respond(with: ["id": id, "error": Self.genericRPCFailureMessage], context: context)
            return
        }
        Self.rpcClient.send(
            endpoint: resolvedNetwork.rpcEndpoint,
            body: httpBody,
            expectedResponseID: id
        ) { response in
            if var json = response {
                json["id"] = id
                Self.respond(with: json, context: context)
            } else {
                Self.respond(
                    with: ["id": id, "error": Self.genericRPCFailureMessage],
                    context: context
                )
            }
        }
    }
    
    private static func respond(with response: [String: Any], context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private static func respond(
        with response: ResponseToExtension,
        for request: SafariRequest,
        context: NSExtensionContext
    ) {
        respond(with: boundedDappResponse(response, for: request), context: context)
    }

    private static func boundedDappResponse(
        _ response: ResponseToExtension,
        for request: SafariRequest
    ) -> [String: Any] {
        if ExtensionBridge.isPayloadWithinLimit(response.json) {
            return response.json
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
    private func openNativeAgent(id: Int, context: NSExtensionContext) {
        Task {
            let opened = await Self.nativeApprovalService.open(
                .showWallet(workflowVersion: ExtensionBridge.workflowVersion)
            )
            guard opened else {
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                return
            }
            Self.respond(with: ["id": id, "opened": true], context: context)
        }
    }

#endif
    
}
