// Copyright © 2021 Tokenary. All rights reserved.

import SafariServices

let SFExtensionMessageKey = "message"

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    
    private var context: NSExtensionContext?
    private let queue = DispatchQueue(label: "SafariWebExtensionHandler", qos: .default)
    
    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems[0] as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey],
              let data = try? JSONSerialization.data(withJSONObject: message, options: []) else { return }
        
        let jsonDecoder = JSONDecoder()
        if let internalSafariRequest = try? jsonDecoder.decode(InternalSafariRequest.self, from: data) {
            let id = internalSafariRequest.id
            switch internalSafariRequest.subject {
            case .getResponse:
                #if !os(macOS)
                if let response = ExtensionBridge.getResponse(id: id) {
                    self.context = context
                    respond(with: response)
                    ExtensionBridge.removeResponse(id: id)
                }
                #else
                break
                #endif
            case .didCompleteRequest:
                ExtensionBridge.removeResponse(id: id)
            }
        } else if let query = String(data: data, encoding: .utf8)?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let request = SafariRequest(query: query),
                  let url = URL(string: "tokenary://safari?request=\(query)") {
            self.context = context
            if case let .ethereum(ethereumRequest) = request.body,
               ethereumRequest.method == .switchEthereumChain || ethereumRequest.method == .addEthereumChain {
                if let chain = ethereumRequest.switchToChain {
                    let responseBody = ResponseToExtension.Ethereum(results: [ethereumRequest.address], chainId: chain.hexStringId, rpcURL: chain.nodeURLString)
                    let response = ResponseToExtension(for: request, body: .ethereum(responseBody))
                    respond(with: response.json)
                } else {
                    let response = ResponseToExtension(for: request, error: "Failed to switch chain")
                    respond(with: response.json)
                }
            } else {
                ExtensionBridge.makeRequest(id: request.id)
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                poll(id: request.id)
            }
        }
    }
    
    private func poll(id: Int) {
        if let response = ExtensionBridge.getResponse(id: id) {
            respond(with: response)
            #if os(macOS)
            ExtensionBridge.removeResponse(id: id)
            #endif
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.poll(id: id)
            }
        }
    }
    
    private func respond(with response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context?.completeRequest(returningItems: [item], completionHandler: nil)
        context = nil
    }
    
}
