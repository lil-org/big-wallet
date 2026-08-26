// ∅ 2026 lil org

import Foundation

protocol SafariRequestBody {
    var responseUpdatesStoredConfiguration: Bool { get }
}

struct SafariRequest {

    let id: Int
    let name: String
    let provider: InpageProvider
    let body: Body
    let host: String
    let configurationKey: String
    let favicon: String?
    let enqueueAttempt: String
    let admissionDeadline: Date
    let workflowVersion: Int

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

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        self.init(json: json)
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int,
              let name = json["name"] as? String,
              let jsonBody = json["body"] as? [String: Any],
              let providerValue = json["provider"] as? String,
              let provider = InpageProvider(rawValue: providerValue),
              provider != .multiple,
              let host = json["host"] as? String,
              let configurationKey = json["configurationKey"] as? String,
              let enqueueAttempt = json["enqueueAttempt"] as? String,
              let admissionDeadlineValue = json["admissionDeadline"],
              CFGetTypeID(admissionDeadlineValue as CFTypeRef) != CFBooleanGetTypeID(),
              let admissionDeadlineMilliseconds = admissionDeadlineValue as? Int,
              admissionDeadlineMilliseconds > 0,
              admissionDeadlineMilliseconds <= 9_007_199_254_740_991,
              let workflowVersion = json["workflowVersion"] as? Int
        else { return nil }
        
        self.id = id
        self.name = name
        self.host = host
        self.configurationKey = configurationKey
        self.enqueueAttempt = enqueueAttempt
        self.admissionDeadline = Date(
            timeIntervalSince1970: TimeInterval(admissionDeadlineMilliseconds) / 1_000
        )
        self.workflowVersion = workflowVersion

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
