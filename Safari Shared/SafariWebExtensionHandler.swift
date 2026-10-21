// ∅ 2026 lil org

import SafariServices

let SFExtensionMessageKey = "message"

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let dispatcher: NativeMessageDispatcher = {
        let bridge = ExtensionBridge.shared
        let rpcClient = SafariRPCClient()
        let poller = ResponseDeliveryPoller(
            responseStatus: { handle, configurationKey in
                await bridge.responseStatus(handle: handle, configurationKey: configurationKey)
            },
            maintain: { handle, configurationKey, maintenance in
#if os(macOS)
                let result = await NativeApprovalService.live.reconcile(
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
                    requestToken: handle.requestToken,
                    profileIdentifier: handle.profileIdentifier
                )
            }
        )
#if os(macOS)
        let policy = NativeMessageDispatcher.ApprovalPolicy.native
#else
        let policy = NativeMessageDispatcher.ApprovalPolicy.popup
#endif
        return NativeMessageDispatcher(policy: policy, dependencies: .init(
            bridge: bridge,
            materialize: { await DappRequestAdmission.shared.materialize(handle: $0) },
            reconcile: { reference, intent in
#if os(macOS)
                let nativeIntent: NativeApprovalService.ReconciliationIntent
                switch intent {
                case .admission: nativeIntent = .admission
                case .focus: nativeIntent = .focus
                }
                        return await NativeApprovalService.live.reconcile(
                    .init(handle: reference.handle, configurationKey: reference.configurationKey, expectedNonce: reference.expectedNonce),
                    intent: nativeIntent
                )
#else
                return .unavailable
#endif
            },
            pollResponse: { await poller.poll(handle: $0, configurationKey: $1, maintenance: $2) },
            rpcNetwork: { Nodes.resolution(chainId: $0).resolvedNetwork },
            sendRPC: { try await rpcClient.send(endpoint: $0, request: $1, execution: $2) },
            popup: { request, profileIdentifier in
#if os(macOS)
                .command(.init(status: .ignored, approvalState: nil))
#else
                await PopupRequestSessions.dispatch(request: request, profileIdentifier: profileIdentifier)
#endif
            },
            privatePopup: { request in
#if os(macOS)
                .command(.init(status: .ignored, approvalState: nil))
#else
                await PopupRequestSessions.dispatchPrivateBrowsing(request: request)
#endif
            },
            openApp: {
#if os(macOS)
                await NativeApprovalService.live.openWallet()
#else
                false
#endif
            },
            invalidateNetworkCache: { CustomNetworkCache.shared.invalidate() }
        ))
    }()

    func beginRequest(with context: NSExtensionContext) {
#if BW_SAFARI_VM_TESTING
        let receivedAt = Date().timeIntervalSince1970
#endif
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              let ingress = NativeRequestContext.extract(
                  from: message,
                  profileIdentifier: item.userInfo?[SFExtensionProfileKey] as? UUID
              ) else {
            context.cancelRequest(withError: NativeMessageDispatcher.Error.invalidMessage)
            return
        }
        // Foundation's borrowed context is handed exclusively to one terminal responder.
        nonisolated(unsafe) let transferredContext = context
        let responder = ExtensionRequestResponder(context: transferredContext)
#if BW_SAFARI_VM_TESTING
        let fixtures = SafariVMFixtures.shared
        let operation = fixtures.capture(requestID: ingress.message.json["id"] as? Int)
        var metadata: [String: Any] = ["profileIdentifier": ingress.context.profileIdentifier.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
                                       "privateBrowsing": ingress.context.privateBrowsing,
                                       "receivedAt": receivedAt]
        switch ingress.context.source {
        case .site(let site, let document):
            metadata["source"] = "site"
            metadata["host"] = site.host
            metadata["configurationKey"] = site.configurationKey
            metadata["tabID"] = document.tabID
            metadata["frameID"] = document.frameID
            metadata["documentID"] = document.documentID.map { $0 as Any } ?? NSNull()
        case .popup: metadata["source"] = "popup"
        case .worker: metadata["source"] = "worker"
        }
        fixtures.event("nativeIngress", requestID: operation.requestID, metadata: metadata, operation: operation)
#endif
        Task {
#if BW_SAFARI_VM_TESTING
            let lockProbe = Task { await SafariVMLockProbe.shared.holdIfRequested() }
#endif
            do {
#if BW_SAFARI_VM_TESTING
                let response = try await SafariVMFixtures.$operation.withValue(operation) {
                    try await Self.dispatcher.dispatch(message: ingress.message, context: ingress.context)
                }
#else
                let response = try await Self.dispatcher.dispatch(
                    message: ingress.message,
                    context: ingress.context
                )
#endif
#if BW_SAFARI_VM_TESTING
                await lockProbe.value
#endif
                responder.complete(with: response)
            } catch {
#if BW_SAFARI_VM_TESTING
                await lockProbe.value
#endif
                responder.cancelRequest(withError: error)
            }
        }
    }
}
