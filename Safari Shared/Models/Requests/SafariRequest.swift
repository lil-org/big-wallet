// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

protocol SafariRequestBody {
    var responseUpdatesStoredConfiguration: Bool { get }
}

// Refactor: make codable
struct SafariRequest {
    
    let id: Int
    let name: String
    let provider: Web3Provider
    let body: Body
    let host: String
    let favicon: String?
    
    enum Body {
        case unknown(Unknown)
        case ethereum(Ethereum)
        case solana(Solana)
        case tezos(Tezos)
        case near(Near)
        
        var value: SafariRequestBody {
            switch self {
            case .ethereum(let body):
                return body
            case .solana(let body):
                return body
            case .tezos(let body):
                return body
            case .near(let body):
                return body
            case .unknown(let body):
                return body
            }
        }
    }
    
    init?(query: String) {
        guard let parametersString = query.removingPercentEncoding,
              let data = parametersString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else { return nil }
        
        guard let id = json["id"] as? Int,
              let name = json["name"] as? String,
              let jsonBody = json["body"] as? [String: Any],
              let host = json["host"] as? String
        else { return nil }
        
        self.id = id
        self.name = name
        self.host = host
        
        if let favicon = json["favicon"] as? String, !favicon.isEmpty {
            if favicon.hasPrefix("//") {
                self.favicon = "https:" + favicon
            } else if favicon.first == "/" {
                self.favicon = "https://" + host + favicon
            } else if favicon.first == "." {
                self.favicon = "https://" + host + favicon.dropFirst()
            } else if favicon.hasPrefix("http") {
                self.favicon = favicon
            } else {
                self.favicon = "https://" + host + "/" + favicon
            }
        } else {
            self.favicon = nil
        }
        
        let provider = Web3Provider(rawValue: json["provider"] as? String ?? "") ?? .unknown
        self.provider = provider
        
        var body: Body?
        switch provider {
        case .ethereum:
            if let request = Ethereum(name: name, json: jsonBody) {
                body = .ethereum(request)
            }
        case .solana:
            if let request = Solana(name: name, json: jsonBody) {
                body = .solana(request)
            }
        case .tezos:
            if let request = Tezos(name: name, json: jsonBody) {
                body = .tezos(request)
            }
        case .near:
            if let request = Near(name: name, json: jsonBody) {
                body = .near(request)
            }
        case .unknown, .multiple:
            if let request = Unknown(name: name, json: jsonBody) {
                body = .unknown(request)
            }
        }
        
        if let body = body {
            self.body = body
        } else {
            return nil
        }
    }
    
}
