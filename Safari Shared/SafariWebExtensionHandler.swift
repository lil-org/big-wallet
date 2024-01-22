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
            case .rpc:
                if let body = internalSafariRequest.body, let chainId = internalSafariRequest.chainId {
                    rpcRequest(chainId: chainId, body: body, context: context)
                } else {
                    context.cancelRequest(withError: HandlerError.empty)
                }
            case .getResponse:
                if let response = ExtensionBridge.getResponse(id: id) {
                    ExtensionBridge.removeResponse(id: id)
                    respond(with: response, context: context)
                } else {
                    context.cancelRequest(withError: HandlerError.empty)
                }
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
    
    private func rpcRequest(chainId: String, body: String, context: NSExtensionContext) {
        guard let chainIdNumber = Int(hexString: chainId),
              let rpcURLString = Nodes.getNode(chainId: chainIdNumber),
              let url = URL(string: rpcURLString),
              let httpBody = body.data(using: .utf8) else {
            // TODO: respond with error
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self?.respond(with: json, context: context)
            } else {
                // TODO: respond with error
                self?.respond(with: ["yo": "body", "chainId": chainId, "result": "gg"], context: context)
            }
        }
        task.resume()
    }
    
    private func respond(with response: [String: Any], context: NSExtensionContext) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
    
}
