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

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems[0] as? NSExtensionItem,
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
            openContainingApp(id: request.id, context: context)
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
                    context.cancelRequest(withError: HandlerError.empty)
                }
            case .cancelRequest:
                ExtensionBridge.removeRequest(id: id)
                context.cancelRequest(withError: HandlerError.empty)
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
            case .accepted(let handle, let approvalRequired, let revisions):
                if !approvalRequired {
                    Self.respond(
                        with: Self.admissionResponse(
                            request: request,
                            handle: handle,
                            approvalRequired: false,
                            revisions: revisions
                        ),
                        context: context
                    )
                    Self.respond(with: response.json, context: context)
                } else {
                    let response = ResponseToExtension(
                        for: request,
                        payload: .error(
                            ProviderResponseError(
                                message: "Unrecognized chain ID",
                                code: 4902
                            )
                        )
                    )
                    Self.respond(with: response.json, context: context)
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
        case .getResponse(let identity):
            guard !privateBrowsing else {
                context.cancelRequest(withError: HandlerError.unsupportedOperation)
                return
            }
            Task {
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

    private var ambientAppURL: URL? {
        var containingAppURL = Bundle.main.bundleURL
        for _ in 0..<3 {
            containingAppURL.deleteLastPathComponent()
        }

        guard containingAppURL.pathExtension == "app" else { return nil }
        let url = containingAppURL.appendingPathComponent("Contents/Helpers/Big Wallet.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
#endif
    
}
