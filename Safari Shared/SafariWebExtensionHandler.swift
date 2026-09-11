// ∅ 2026 lil org

import SafariServices

let SFExtensionMessageKey = "message"

private enum HandlerError: LocalizedError {
    case invalidMessage
    case unsupportedOperation
    case requestPending
    case bridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMessage:
            return "Invalid extension message"
        case .unsupportedOperation:
            return "Unsupported extension operation"
        case .requestPending:
            return "Extension request is pending"
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
    private static let nativeAgentLauncher = NativeAgentLauncher.live
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
                  subject: request.subject,
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
        case .popup:
            Task { @MainActor in
                let response: [String: Any]
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
                Self.respond(
                    with: PopupApprovalStatePresenter.boundedResponse(
                        response,
                        for: request
                    ),
                    context: context
                )
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
                _,
                let nativeDeliveryNonce
            ):
                if ingress.replayOnly || !approvalRequired {
                    Self.respond(
                        with: Self.admissionResponse(
                            request: request,
                            handle: handle,
                            approvalRequired: approvalRequired,
                            revisions: revisions
                        ),
                        context: context
                    )
                    return
                }
#if os(macOS)
                let materializesWalletDependentRequests = false
#else
                let materializesWalletDependentRequests = true
#endif
                switch await PopupRequestSessions.materializeAfterAdmission(
                    handle: handle,
                    materializesWalletDependentRequests:
                        materializesWalletDependentRequests
                ) {
                case .approvalRequired:
#if os(macOS)
                    let launched = await Self.nativeAgentLauncher.open(
                        .approval(
                            workflowVersion: ExtensionBridge.workflowVersion,
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce
                        )
                    )
                    guard launched else {
                        await reconcileAfterNativeLaunchFailure(
                            request: request,
                            handle: handle,
                            nativeDeliveryNonce: nativeDeliveryNonce,
                            revisions: revisions,
                            context: context
                        )
                        return
                    }
#endif
                    Self.respond(
                        with: Self.admissionResponse(
                            request: request,
                            handle: handle,
                            approvalRequired: true,
                            revisions: revisions
                        ),
                        context: context
                    )
                case .responseReady:
                    Self.respond(
                        with: Self.admissionResponse(
                            request: request,
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
        request: SafariRequest,
        handle: ExtensionBridge.Handle,
        approvalRequired: Bool,
        revisions: ExtensionBridge.ProviderRevisions
    ) -> [String: Any] {
        return [
            "id": request.id,
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
                let opened = await Self.nativeAgentLauncher.reactivate(.approval(
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
            guard !privateBrowsing else {
                context.cancelRequest(withError: HandlerError.unsupportedOperation)
                return
            }
            Task { @MainActor in
#if os(macOS)
                let handle = ExtensionBridge.Handle(
                    id: request.id,
                    token: identity.token,
                    profileIdentifier: profileIdentifier
                )
                var nativeExecutionFence: ExtensionBridge.NativeExecutionFence?
                defer { nativeExecutionFence?.release() }
                switch await Self.bridge.load(handle: handle) {
                case .found(let snapshot):
                    let fenceToken = UUID()
                    if snapshot.nativeDecisionStaged ||
                        snapshot.phase == .approving,
                       let fence = await Self.bridge
                        .acquireNativeExecutionFence(
                            handle: handle,
                            token: fenceToken
                        ) {
                        nativeExecutionFence = fence
                        switch await Self.bridge.recordNativeExecutionContext(
                            handle: handle,
                            configurationKey: identity.configurationKey,
                            revisions: identity.revisions,
                            executionDeadline: identity.executionDeadline,
                            fenceToken: fenceToken
                        ) {
                        case .responseReady, .missing:
                            break
                        case .recorded(let executionContext):
                            guard executionContext.fenceToken == fenceToken else {
                                break
                            }
                            guard await ensureNativeApprovalDeliveryIfNeeded(
                                handle: handle,
                                ) else {
                                _ = await Self.bridge
                                    .clearNativeExecutionContext(
                                        handle: handle,
                                        expected: executionContext
                                    )
                                context.cancelRequest(
                                    withError: HandlerError.bridgeUnavailable
                                )
                                return
                            }
                            guard await waitForNativeApprovalFinalization(
                                handle: handle,
                                configurationKey: identity.configurationKey,
                                initialContext: executionContext
                            ) else {
                                context.cancelRequest(
                                    withError: HandlerError.requestPending
                                )
                                return
                            }
                        case .pending:
                            guard await ensureNativeApprovalDeliveryIfNeeded(
                                handle: handle
                            ) else {
                                context.cancelRequest(
                                    withError: HandlerError.bridgeUnavailable
                                )
                                return
                            }
                        case .unavailable:
                            context.cancelRequest(
                                withError: HandlerError.bridgeUnavailable
                            )
                            return
                        }
                    } else if !snapshot.nativeDecisionStaged,
                              snapshot.phase == .queued {
                        guard await ensureNativeApprovalDeliveryIfNeeded(
                            handle: handle
                        ) else {
                            context.cancelRequest(
                                withError: HandlerError.bridgeUnavailable
                            )
                            return
                        }
                    }
                case .missing:
                    break
                case .unavailable:
                    context.cancelRequest(
                        withError: HandlerError.bridgeUnavailable
                    )
                    return
                }
#endif
                switch await Self.bridge.readResponse(
                    id: request.id,
                    configurationKey: identity.configurationKey,
                    requestToken: identity.token.rawValue,
                    profileIdentifier: profileIdentifier
                ) {
                case .response(let response):
                    if case .addsEthereumChain =
                        ResponseToExtension.ConfigurationMutation.classify(response) {
                        CustomNetworkCache.shared.invalidate()
                    }
                    Self.respond(with: response, context: context)
                case .pending:
                    context.cancelRequest(withError: HandlerError.requestPending)
                case .missing:
                    Self.respond(with: [
                        "id": request.id,
                        "missing": true,
                    ], context: context)
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            }
        }
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
        let internalError = ResponseToExtension(
            for: request,
            payload: .error(.internalError)
        ).json
        if ExtensionBridge.isPayloadWithinLimit(internalError) {
            return internalError
        }
        return [
            "id": request.id,
            "name": "",
            "provider": request.provider.rawValue,
            "error": "",
            "errorCode": ProviderResponseError.internalErrorCode,
        ]
    }

#if os(macOS)
    @MainActor
    private func ensureNativeApprovalDeliveryIfNeeded(
        handle: ExtensionBridge.Handle
    ) async -> Bool {
        switch await Self.bridge.load(handle: handle) {
        case .found(let snapshot):
            guard snapshot.phase != .responded else { return true }
            return await Self.nativeAgentLauncher.open(.approval(
                workflowVersion: ExtensionBridge.workflowVersion,
                handle: handle,
                nativeDeliveryNonce: snapshot.nativeDeliveryNonce
            ))
        case .missing:
            return true
        case .unavailable:
            return false
        }
    }

    private func waitForNativeApprovalFinalization(
        handle: ExtensionBridge.Handle,
        configurationKey: String,
        initialContext: ExtensionBridge.NativeExecutionContext
    ) async -> Bool {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt.addingReportingOverflow(
            170_000_000_000
        ).partialValue
        var nextDeliveryCheck = startedAt
        if Date() >= initialContext.executionDeadline {
            _ = await Self.bridge.clearNativeExecutionContext(
                handle: handle,
                expected: initialContext
            )
            return false
        }
        while !Task.isCancelled,
              DispatchTime.now().uptimeNanoseconds < deadline {
            switch await Self.bridge.readResponse(
                id: handle.id,
                configurationKey: configurationKey,
                requestToken: handle.requestToken,
                profileIdentifier: handle.profileIdentifier
            ) {
            case .response, .missing:
                return true
            case .pending:
                switch await Self.bridge.load(handle: handle) {
                case .found(let snapshot):
                    if snapshot.phase == .queued,
                       Date() >= initialContext.executionDeadline {
                        _ = await Self.bridge.clearNativeExecutionContext(
                            handle: handle,
                            expected: initialContext
                        )
                        return false
                    }
                    if snapshot.phase == .queued,
                       snapshot.nativeDecisionStaged,
                       snapshot.nativeDeliveryReceipt == nil {
                        _ = await Self.bridge.clearNativeExecutionContext(
                            handle: handle,
                            expected: initialContext
                        )
                        return false
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if snapshot.phase == .queued,
                       snapshot.nativeDecisionStaged,
                       now >= nextDeliveryCheck {
                        guard await ensureNativeApprovalDeliveryIfNeeded(
                            handle: handle
                        ) else {
                            _ = await Self.bridge.clearNativeExecutionContext(
                                handle: handle,
                                expected: initialContext
                            )
                            return false
                        }
                        nextDeliveryCheck = now.addingReportingOverflow(
                            1_000_000_000
                        ).partialValue
                    }
                case .missing:
                    return true
                case .unavailable:
                    break
                }
            case .unavailable:
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        _ = await Self.bridge.clearNativeExecutionContext(
            handle: handle,
            expected: initialContext
        )
        return false
    }

    private func openNativeAgent(id: Int, context: NSExtensionContext) {
        Task {
            let opened = await Self.nativeAgentLauncher.open(
                .showWallet(workflowVersion: ExtensionBridge.workflowVersion)
            )
            guard opened else {
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                return
            }
            Self.respond(with: ["id": id, "opened": true], context: context)
        }
    }

    private func reconcileAfterNativeLaunchFailure(
        request: SafariRequest,
        handle: ExtensionBridge.Handle,
        nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        revisions: ExtensionBridge.ProviderRevisions,
        context: NSExtensionContext
    ) async {
        switch await Self.bridge.load(handle: handle) {
        case .found(let snapshot):
            guard snapshot.nativeDeliveryNonce == nativeDeliveryNonce else {
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                return
            }
            if snapshot.phase == .responded {
                Self.respond(
                    with: Self.admissionResponse(
                        request: request,
                        handle: handle,
                        approvalRequired: false,
                        revisions: revisions
                    ),
                    context: context
                )
                return
            }
            guard Self.nativeLaunchWasDelivered(
                      await NativeAgentLauncher.currentApprovalDeliveryStatus(
                          handle: handle,
                          nativeDeliveryNonce: nativeDeliveryNonce
                      )
                  ) else {
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                return
            }
            Self.respond(
                with: Self.admissionResponse(
                    request: request,
                    handle: handle,
                    approvalRequired: true,
                    revisions: revisions
                ),
                context: context
            )
        case .missing, .unavailable:
            context.cancelRequest(withError: HandlerError.bridgeUnavailable)
        }
    }

    static func nativeLaunchWasDelivered(
        _ status: NativeAgentLauncher.ExistingDeliveryStatus
    ) -> Bool {
        status == .delivered
    }
#endif
    
}
