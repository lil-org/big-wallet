// ∅ 2026 lil org

import Foundation

struct SafariRequest {

    let id: Int
    let name: String
    let provider: InpageProvider
    let body: Body
    let host: String
    let configurationKey: String
    let favicon: String?
    let enqueueAttempt: String
    let admissionDeadlineMilliseconds: Int
    let workflowVersion: Int
    var authority: ExtensionBridge.AuthorityVersion?
    var authorizedAccount: WalletAccountDescriptor?
    var connectedAccounts: [WalletAccountDescriptor] = []

    var admissionDeadline: Date {
        Date(timeIntervalSince1970: TimeInterval(admissionDeadlineMilliseconds) / 1_000)
    }
    
    enum Body {
        case unknown(Unknown)
        case ethereum(Ethereum)
        case solana(Solana)

        init?(provider: InpageProvider, name: String, json: [String: Any]) {
            switch provider {
            case .ethereum:
                guard let body = Ethereum(name: name, json: json) else { return nil }
                self = .ethereum(body)
            case .solana:
                guard let body = Solana(name: name, json: json) else { return nil }
                self = .solana(body)
            case .unknown:
                guard let body = Unknown(name: name, json: json) else { return nil }
                self = .unknown(body)
            case .multiple:
                return nil
            }
        }
    }

    init(
        id: Int,
        name: String,
        provider: InpageProvider,
        body: Body,
        host: String,
        configurationKey: String,
        favicon: String?,
        enqueueAttempt: String,
        admissionDeadlineMilliseconds: Int,
        authority: ExtensionBridge.AuthorityVersion?,
        authorizedAccount: WalletAccountDescriptor?
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.body = body
        self.host = host
        self.configurationKey = configurationKey
        self.favicon = favicon
        self.enqueueAttempt = enqueueAttempt
        self.admissionDeadlineMilliseconds = admissionDeadlineMilliseconds
        workflowVersion = ExtensionBridge.workflowVersion
        self.authority = authority
        self.authorizedAccount = authorizedAccount
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
        self.admissionDeadlineMilliseconds = admissionDeadlineMilliseconds
        self.workflowVersion = workflowVersion
        authority = ExtensionBridge.AuthorityVersion(rawValue: json["authority"])
        authorizedAccount = nil
        
        favicon = Self.normalizedFavicon(json["favicon"] as? String, host: host)
        
        self.provider = provider
        
        guard let body = Body(provider: provider, name: name, json: jsonBody) else { return nil }
        self.body = body
    }

    static func normalizedFavicon(_ favicon: String?, host: String) -> String? {
        guard let favicon, !favicon.isEmpty else { return nil }
        if favicon.hasPrefix("//") { return "https:" + favicon }
        if favicon.first == "/" { return "https://" + host + favicon }
        if favicon.first == "." { return "https://" + host + favicon.dropFirst() }
        if favicon.hasPrefix("http") { return favicon }
        return "https://" + host + "/" + favicon
    }
    
}
