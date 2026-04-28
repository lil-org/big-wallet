// ∅ 2026 lil org

import Foundation

struct ResponseToExtension {
    
    let id: Int
    let json: [String: Any]
    
    enum Body {
        case ethereum(Ethereum)
        case solana(Solana)
        case multiple(Multiple)
        
        var json: [String: Any] {
            let data: Data?
            let jsonEncoder = JSONEncoder()

            switch self {
            case .ethereum(let body):
                data = try? jsonEncoder.encode(body)
            case .solana(let body):
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
        
        var provider: InpageProvider {
            switch self {
            case .ethereum:
                return .ethereum
            case .solana:
                return .solana
            case .multiple:
                return .multiple
            }
        }
    }
    
    init(for request: SafariRequest,
         body: Body? = nil,
         error: String? = nil,
         errorCode: Int? = nil,
         errorPublicKey: String? = nil,
         errorSignature: String? = nil) {
        self.id = request.id
        var json: [String: Any] = [
            "id": request.id,
            "name": request.name
        ]
        
        if let error = error {
            json["error"] = error
            json["provider"] = request.provider.rawValue
            if let errorCode {
                json["errorCode"] = errorCode
            }
            if let errorPublicKey {
                json["errorPublicKey"] = errorPublicKey
            }
            if let errorSignature {
                json["errorSignature"] = errorSignature
            }
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
