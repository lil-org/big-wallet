// ∅ 2026 lil org

import SafariServices

let SFExtensionMessageKey = "message"

private enum HandlerError: Error {
    case empty
}

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let rpcClient = SafariRPCClient()

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems[0] as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              let data = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            context.cancelRequest(withError: HandlerError.empty)
            return
        }
        let jsonDecoder = JSONDecoder()
        if let internalSafariRequest = try? jsonDecoder.decode(InternalSafariRequest.self, from: data) {
            let id = internalSafariRequest.id
            switch internalSafariRequest.subject {
            case .rpc:
                if let body = internalSafariRequest.body, let chainId = internalSafariRequest.chainId {
                    rpcRequest(id: id, chainId: chainId, body: body, context: context)
                } else {
                    context.cancelRequest(withError: HandlerError.empty)
                }
            case .getResponse:
                if let response = ExtensionBridge.getResponse(id: id) {
                    ExtensionBridge.removeResponse(id: id)
                    if response["name"] as? String ==
                        SafariRequest.Ethereum.Method.addEthereumChain.rawValue,
                       response["error"] == nil {
                        CustomNetworkCache.shared.invalidate()
                    }
                    Self.respond(with: response, context: context)
                } else {
                    context.cancelRequest(withError: HandlerError.empty)
                }
            case .cancelRequest:
                ExtensionBridge.removeRequest(id: id)
                context.cancelRequest(withError: HandlerError.empty)
            }
        } else if let query = appRequestQuery(from: message),
                  let request = SafariRequest(query: query),
                  let url = SafariRequest.appRequestURL(query: query) {
            if case let .ethereum(ethereumRequest) = request.body, ethereumRequest.method == .switchEthereumChain {
                if let switchToChainId = ethereumRequest.switchToChainId,
                   Nodes.url(chainId: switchToChainId) != nil {
                    let chainId = String.hex(switchToChainId, withPrefix: true)
                    let responseBody = ResponseToExtension.Ethereum(results: [ethereumRequest.address], chainId: chainId)
                    let response = ResponseToExtension(for: request, body: .ethereum(responseBody))
                    Self.respond(with: response.json, context: context)
                } else {
                    let response = ResponseToExtension(for: request, error: "failed to switch chain")
                    Self.respond(with: response.json, context: context)
                }
            } else {
                ExtensionBridge.makeRequest(id: request.id)
#if os(macOS)
                openAmbientApp(with: url)
#endif
                context.cancelRequest(withError: HandlerError.empty)
            }
        } else {
            context.cancelRequest(withError: HandlerError.empty)
        }
    }

    private func appRequestQuery(from message: Any) -> String? {
        let message = messageWithAmbientAgentInfo(message)
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []) else { return nil }
        return String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    private func messageWithAmbientAgentInfo(_ message: Any) -> Any {
#if os(macOS) && !DEBUG
        guard var json = message as? [String: Any],
              let ambientAppURL,
              let userInfo = AmbientAgentTerminationRequest.userInfo(forBundleAt: ambientAppURL) else {
            return message
        }

        json[AmbientAgentTerminationRequest.safariRequestUserInfoKey] = userInfo
        return json
#else
        return message
#endif
    }
    
    private func rpcRequest(id: Int, chainId: String, body: String, context: NSExtensionContext) {
        guard let chainIdNumber = Int(hexString: chainId),
              let url = Nodes.url(chainId: chainIdNumber),
              let httpBody = body.data(using: .utf8) else {
            Self.respond(with: ["id": id, "error": "something went wrong"], context: context)
            return
        }

        Self.rpcClient.send(url: url, body: httpBody) { response in
            if var json = response {
                if json["id"] == nil { json["id"] = id }
                Self.respond(with: json, context: context)
            } else {
                Self.respond(with: ["id": id, "error": "something went wrong"], context: context)
            }
        }
    }
    
    private static func respond(with response: [String: Any], context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

#if os(macOS)
    private func openAmbientApp(with requestURL: URL) {
        guard let ambientAppURL else {
            NSWorkspace.shared.open(requestURL)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
#if DEBUG
        let arguments = AmbientPseudoLocalizationLaunchMode.ambientLaunchArguments()
        if !arguments.isEmpty {
            configuration.arguments = arguments
        }
#endif
        NSWorkspace.shared.open([requestURL], withApplicationAt: ambientAppURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(requestURL)
            }
        }
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
