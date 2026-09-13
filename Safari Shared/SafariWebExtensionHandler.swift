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
        case .getManualSwitchRequests(let cursor):
            Task {
                switch await Self.bridge.listManualSwitchRequests(
                    profileIdentifier: profileIdentifier,
                    cursor: cursor
                ) {
                case .available(let page):
                    Self.respond(with: [
                        "id": request.id,
                        "requests": page.requests.map(\.json),
                        "nextCursor": page.nextCursor as Any? ?? NSNull(),
                    ], context: context)
                case .invalidCursor:
                    context.cancelRequest(withError: HandlerError.invalidMessage)
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                }
            }
        case .getManualSwitchResponse(let identity):
            readResponse(
                id: request.id,
                identity: identity,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                mode: .manualRecovery,
                context: context
            )
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
            readResponse(
                id: request.id,
                identity: identity,
                profileIdentifier: profileIdentifier,
                privateBrowsing: privateBrowsing,
                mode: .page,
                context: context
            )
        }
    }

    private enum ResponseReadMode {
        case page, manualRecovery
    }

    private func readResponse(
        id: Int,
        identity: InternalSafariRequest.ResponseIdentity,
        profileIdentifier: UUID?,
        privateBrowsing: Bool,
        mode: ResponseReadMode,
        context: NSExtensionContext
    ) {
        guard !privateBrowsing else {
            context.cancelRequest(withError: HandlerError.unsupportedOperation)
            return
        }
        Task { @MainActor in
            let handle = ExtensionBridge.Handle(
                id: id,
                token: identity.token,
                profileIdentifier: profileIdentifier
            )
            var manualSnapshot: ExtensionBridge.Snapshot?
            if mode == .manualRecovery {
                switch await Self.bridge.loadManualSwitch(
                    handle: handle,
                    configurationKey: identity.configurationKey
                ) {
                case .found(let snapshot):
                    manualSnapshot = snapshot
                    if snapshot.phase != .responded {
#if os(macOS)
                        guard await NativeAgentLauncher.hasCompatibleApprovalDelivery(
                            handle: handle,
                            nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                        ) else {
                            Self.respondPending(id: id, mode: mode, context: context)
                            return
                        }
#else
                        Self.respondPending(id: id, mode: mode, context: context)
                        return
#endif
                    }
                case .missing:
                    Self.respond(with: ["id": id, "missing": true], context: context)
                    return
                case .unavailable:
                    context.cancelRequest(withError: HandlerError.bridgeUnavailable)
                    return
                }
            }
#if os(macOS)
            var nativeExecutionFence: ExtensionBridge.NativeExecutionFence?
            defer { nativeExecutionFence?.release() }
            let loaded: ExtensionBridge.SnapshotResult = if let manualSnapshot {
                .found(manualSnapshot)
            } else {
                await Self.bridge.load(handle: handle)
            }
            switch loaded {
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
                            mode: mode
                        ) else {
                            _ = await Self.bridge
                                .clearNativeExecutionContext(
                                    handle: handle,
                                    expected: executionContext
                                )
                            Self.respondPending(
                                id: id, mode: mode, context: context,
                                error: .bridgeUnavailable
                            )
                            return
                        }
                        guard await waitForNativeApprovalFinalization(
                            handle: handle,
                            configurationKey: identity.configurationKey,
                            initialContext: executionContext,
                            mode: mode
                        ) else {
                            Self.respondPending(id: id, mode: mode, context: context)
                            return
                        }
                    case .pending:
                        guard await ensureNativeApprovalDeliveryIfNeeded(
                            handle: handle,
                            mode: mode
                        ) else {
                            Self.respondPending(
                                id: id, mode: mode, context: context,
                                error: .bridgeUnavailable
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
                        handle: handle,
                        mode: mode
                    ) else {
                        Self.respondPending(
                            id: id, mode: mode, context: context,
                            error: .bridgeUnavailable
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
                id: id,
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
                Self.respondPending(id: id, mode: mode, context: context)
            case .missing:
                Self.respond(with: [
                    "id": id,
                    "missing": true,
                ], context: context)
            case .unavailable:
                context.cancelRequest(withError: HandlerError.bridgeUnavailable)
            }
        }
    }

    private static func respondPending(
        id: Int,
        mode: ResponseReadMode,
        context: NSExtensionContext,
        error: HandlerError = .requestPending
    ) {
        if mode == .manualRecovery {
            respond(with: ["id": id, "pending": true], context: context)
        } else {
            context.cancelRequest(withError: error)
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
        handle: ExtensionBridge.Handle,
        mode: ResponseReadMode
    ) async -> Bool {
        switch await Self.bridge.load(handle: handle) {
        case .found(let snapshot):
            guard snapshot.phase != .responded else { return true }
            if mode == .manualRecovery {
                return await NativeAgentLauncher.hasCompatibleApprovalDelivery(
                    handle: handle,
                    nativeDeliveryNonce: snapshot.nativeDeliveryNonce
                )
            }
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
        initialContext: ExtensionBridge.NativeExecutionContext,
        mode: ResponseReadMode
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
                            handle: handle,
                            mode: mode
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
