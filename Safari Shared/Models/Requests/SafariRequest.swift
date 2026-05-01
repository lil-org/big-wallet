// ∅ 2026 lil org

import Foundation

protocol SafariRequestBody {
    var responseUpdatesStoredConfiguration: Bool { get }
}

struct SafariRequest {

    private static let appRequestURLPrefix = "bigwallet://safari?request="
    private static let webRequestURLPrefix = "https://lil.org/extension?query="
    private static let requestURLPrefixes = [appRequestURLPrefix, webRequestURLPrefix]

    let id: Int
    let name: String
    let provider: InpageProvider
    let body: Body
    let host: String
    let favicon: String?
#if os(macOS)
    let ambientAgent: [String: String]?
#endif
    
    enum Body {
        case unknown(Unknown)
        case ethereum(Ethereum)
        case solana(Solana)

        var value: SafariRequestBody {
            switch self {
            case .ethereum(let body):
                return body
            case .solana(let body):
                return body
            case .unknown(let body):
                return body
            }
        }
    }
    
    static func appRequestURL(query: String) -> URL? {
        return URL(string: appRequestURLPrefix + query)
    }

    init?(appRequestURLString: String) {
        guard appRequestURLString.hasPrefix(Self.appRequestURLPrefix) else { return nil }
        self.init(query: String(appRequestURLString.dropFirst(Self.appRequestURLPrefix.count)))
    }

    init?(urlString: String) {
        guard let prefix = Self.requestURLPrefixes.first(where: { urlString.hasPrefix($0) }) else { return nil }
        self.init(query: String(urlString.dropFirst(prefix.count)))
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
#if os(macOS)
        self.ambientAgent = AmbientAgentTerminationRequest.userInfo(in: json)
#endif
        
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
        
        let provider = InpageProvider(rawValue: json["provider"] as? String ?? "") ?? .unknown
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
