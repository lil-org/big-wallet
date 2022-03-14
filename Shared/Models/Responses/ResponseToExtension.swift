// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct ResponseToExtension {
    
    let id: Int
    let json: [String: AnyHashable]
    
    enum Body {
        case ethereum(Ethereum)
        case solana(Solana)
        case tezos(Tezos)
        
        var json: [String: AnyHashable] {
            let data: Data?
            let jsonEncoder = JSONEncoder()
            
            switch self {
            case .ethereum(let body):
                data = try? jsonEncoder.encode(body)
            case .solana(let body):
                data = try? jsonEncoder.encode(body)
            case .tezos(let body):
                data = try? jsonEncoder.encode(body)
            }
            
            if let data = data, let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: AnyHashable] {
                return dict
            } else {
                return [:]
            }
        }
        
        var provider: Web3Provider {
            switch self {
            case .ethereum:
                return .ethereum
            case .solana:
                return .solana
            case .tezos:
                return .tezos
            }
        }
    }
    
    init(for request: SafariRequest, body: Body? = nil, error: String? = nil) {
        self.id = request.id
        let provider = (body?.provider ?? request.provider).rawValue
        
        var json: [String: AnyHashable] = [
            "id": request.id,
            "provider": provider,
            "name": request.name
        ]
        
        if let error = error {
            json["error"] = error
        }
        
        var bodyJSON = body?.json ?? [:]
        json.merge(bodyJSON) { (current, _) in current }
        
        if request.body.value.responseUpdatesStoredConfiguration {
            if !bodyJSON.isEmpty {
                bodyJSON["provider"] = provider
            }
            
            json["configurationToStore"] = bodyJSON
        }
        
        self.json = json
    }
    
}
