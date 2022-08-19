// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct ResponseToExtension {
    
    let id: Int
    let json: [String: Any]
    
    enum Body {
        case ethereum(Ethereum)
        case solana(Solana)
        case tezos(Tezos)
        case near(Near)
        case multiple(Multiple)
        
        var json: [String: Any] {
            let data: Data?
            let jsonEncoder = JSONEncoder()
            
            switch self {
            case .ethereum(let body):
                data = try? jsonEncoder.encode(body)
            case .solana(let body):
                data = try? jsonEncoder.encode(body)
            case .near(let body):
                data = try? jsonEncoder.encode(body)
            case .tezos(let body):
                data = try? jsonEncoder.encode(body)
            case .multiple(let body):
                let dict: [String: Any] = [
                    "bodies": body.bodies.map { $0.json },
                    "providersToDisconnect": body.providersToDisconnect.map { $0.rawValue },
                    "provider": provider.rawValue
                ]
                return dict
            }
            
            if let data = data, var dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                dict["provider"] = provider.rawValue
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
            case .near:
                return .near
            case .tezos:
                return .tezos
            case .multiple:
                return .multiple
            }
        }
    }
    
    init(for request: SafariRequest, body: Body? = nil, error: String? = nil) {
        self.id = request.id
        var json: [String: Any] = [
            "id": request.id,
            "name": request.name
        ]
        
        if let error = error {
            json["error"] = error
        }
        
        let bodyJSON = body?.json ?? [:]
        json.merge(bodyJSON) { (current, _) in current }
                
        if request.body.value.responseUpdatesStoredConfiguration, error == nil {
            if let bodies = bodyJSON["bodies"] {
                json["configurationToStore"] = bodies
            } else {
                json["configurationToStore"] = bodyJSON
            }
        }
        
        self.json = json
    }
    
}
