import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import SafariServices

let SFExtensionMessageKey = "message"

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    @MainActor
    private static let dispatcher = makeDispatcher()

    @MainActor
    private static func makeDispatcher() -> NativeMessageDispatcher {
        let services = ApplicationServices.shared
        let system = services.authority
        let bridge = system.requests
        let networks = system.networks
#if os(macOS)
        let nativeApprovals = services.nativeApprovals
#else
        let popupSessions = services.popupSessions
#endif
        let poller = ResponseDeliveryPoller(
            responseStatus: { await bridge.responseStatus(handle: $0, configurationKey: $1) },
            maintain: { handle, configurationKey, maintenance in
#if os(macOS)
                let result = await nativeApprovals.reconcile(
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
                await bridge.prepareResponseDelivery(id: handle.id, configurationKey: configurationKey,
                    requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier)
            }
        )
#if os(macOS)
        let policy = NativeMessageDispatcher.ApprovalPolicy.native
#else
        let policy = NativeMessageDispatcher.ApprovalPolicy.popup
#endif
        return NativeMessageDispatcher(policy: policy, dependencies: .init(
            bridge: bridge,
            materialize: { await system.admission.materialize(handle: $0) },
            reconcile: { reference, intent in
#if os(macOS)
                await nativeApprovals.reconcile(
                    .init(handle: reference.handle, configurationKey: reference.configurationKey,
                        expectedNonce: reference.expectedNonce, isToolbarAction: reference.isToolbarAction),
                    intent: intent == .admission ? .admission : .focus
                )
#else
                .unavailable
#endif
            },
            pollResponse: { await poller.poll(handle: $0, configurationKey: $1, maintenance: $2) },
            rpc: PublicRPCForwarder(service: SafariRPCService(limits: .live, clock: .live, serializeRequest: { try $0.serialize() }), client: services.safariRPC,
                network: { networks.resolve(chainId: $0).resolvedNetwork }),
            popup: { request, profileIdentifier in
#if os(macOS)
                .command(.init(status: .ignored, approvalState: nil))
#else
                await popupSessions.dispatch(request: request, profileIdentifier: profileIdentifier)
#endif
            },
            privatePopup: { request in
#if os(macOS)
                .command(.init(status: .ignored, approvalState: nil))
#else
                await popupSessions.privateBrowsingResponse(for: request)
#endif
            },
            openApp: {
#if os(macOS)
                await nativeApprovals.openWallet()
#else
                false
#endif
            },
            invalidateNetworkCache: { system.invalidateNetworkCache() }
        ), messages: system.messages)
    }

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
