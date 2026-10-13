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
                let result = await NativeApprovalService.live.reconcile(
                    .init(handle: reference.handle, configurationKey: reference.configurationKey, expectedNonce: reference.expectedNonce),
                    intent: nativeIntent
                )
                switch result {
                case .pending: return .pending
                case .responseReady: return .responseReady
                case .opened: return .opened
                case .missing: return .missing
                case .unavailable: return .unavailable
                }
#else
                return .unavailable
#endif
            },
            pollResponse: { await poller.poll(handle: $0, configurationKey: $1, maintenance: $2) },
            rpcNetwork: { Nodes.resolution(chainId: $0).resolvedNetwork },
            sendRPC: { try await rpcClient.send(endpoint: $0, body: $1, expectedResponseID: $2) },
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
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              var json = WireProtocol.JSONObject(message)?.json,
              case .value(let privateBrowsing) = ExtensionBridge.takePrivateBrowsing(from: &json),
              let object = WireProtocol.JSONObject(json) else {
            context.cancelRequest(withError: NativeMessageDispatcher.Error.invalidMessage)
            return
        }
        let profileIdentifier = item.userInfo?[SFExtensionProfileKey] as? UUID
        // Foundation's borrowed context is handed exclusively to one terminal responder.
        nonisolated(unsafe) let transferredContext = context
        let responder = ExtensionRequestResponder(context: transferredContext)
        Task {
            do {
                responder.complete(with: try await Self.dispatcher.dispatch(
                    message: object,
                    profileIdentifier: profileIdentifier,
                    privateBrowsing: privateBrowsing
                ))
            } catch {
                responder.cancelRequest(withError: error)
            }
        }
    }
}
