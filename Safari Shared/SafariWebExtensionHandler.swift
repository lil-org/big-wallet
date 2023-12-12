// Copyright © 2021 Tokenary. All rights reserved.

import SafariServices

let SFExtensionMessageKey = "message"

private enum HandlerError: Error {
    case empty
}

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    
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
            case .getResponse:
                if let response = ExtensionBridge.getResponse(id: id) {
                    respond(with: response, context: context)
                    ExtensionBridge.removeResponse(id: id)
                } else {
                    context.cancelRequest(withError: HandlerError.empty)
                }
            case .didCompleteRequest:
                ExtensionBridge.removeResponse(id: id)
                context.cancelRequest(withError: HandlerError.empty)
            case .cancelRequest:
                ExtensionBridge.removeRequest(id: id)
                context.cancelRequest(withError: HandlerError.empty)
            }
        } else if let query = String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let request = SafariRequest(query: query),
                  let url = URL(string: "tokenary://safari?request=\(query)") {
            if case let .ethereum(ethereumRequest) = request.body,
               ethereumRequest.method == .switchEthereumChain || ethereumRequest.method == .addEthereumChain {
                if let switchToChainId = ethereumRequest.switchToChainId, let rpcURL = Nodes.getNode(chainId: switchToChainId) {
                    let chainId = String.hex(switchToChainId, withPrefix: true)
                    let responseBody = ResponseToExtension.Ethereum(results: [ethereumRequest.address], chainId: chainId, rpcURL: rpcURL)
                    let response = ResponseToExtension(for: request, body: .ethereum(responseBody))
                    respond(with: response.json, context: context)
                } else {
                    let response = ResponseToExtension(for: request, error: "Failed to switch chain")
                    respond(with: response.json, context: context)
                }
            } else {
                ExtensionBridge.makeRequest(id: request.id)
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                context.cancelRequest(withError: HandlerError.empty)
            }
        } else {
            context.cancelRequest(withError: HandlerError.empty)
        }
    }
    
    private func respond(with response: [String: Any], context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
    
}
