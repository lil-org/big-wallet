// ∅ 2026 lil org

import Foundation

public struct SafariRequest: Sendable {

    public let id: Int
    public let name: String
    public let provider: InpageProvider
    public let body: Body
    public let host: String
    public let configurationKey: String
    public let enqueueAttempt: String
    public let admissionDeadlineMilliseconds: Int
    public let workflowVersion: Int
    public var authority: RequestAuthorityVersion?
    public var authorizedAccount: WalletAccountDescriptor?
    public var manualSwitchContext: ManualSwitchContext?

    public var admissionDeadline: Date {
        Date(timeIntervalSince1970: TimeInterval(admissionDeadlineMilliseconds) / 1_000)
    }
    
    public enum Body: Sendable {
        case unknown(Unknown)
        case ethereum(Ethereum)
        case solana(Solana)

        public init?(provider: InpageProvider, name: String, json: [String: Any]) {
            switch provider {
            case .ethereum:
                guard let body = Ethereum(name: name, json: json) else { return nil }
                self = .ethereum(body)
            case .solana:
                guard let body = Solana(name: name, json: json) else { return nil }
                self = .solana(body)
            case .unknown:
                guard let body = Unknown(name: name) else { return nil }
                self = .unknown(body)
            case .multiple:
                return nil
            }
        }
    }

    public init(
        id: Int,
        name: String,
        provider: InpageProvider,
        body: Body,
        host: String,
        configurationKey: String,
        enqueueAttempt: String,
        admissionDeadlineMilliseconds: Int,
        authority: RequestAuthorityVersion?,
        authorizedAccount: WalletAccountDescriptor?
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.body = body
        self.host = host
        self.configurationKey = configurationKey
        self.enqueueAttempt = enqueueAttempt
        self.admissionDeadlineMilliseconds = admissionDeadlineMilliseconds
        workflowVersion = WireProtocol.workflowVersion
        self.authority = authority
        self.authorizedAccount = authorizedAccount
    }
    
    public init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        self.init(json: json)
    }

    public init?(wire: WireProtocol.ValidatedObject) {
        guard wire.contract == .dappRequest else { return nil }
        let json = wire.json
        guard let authorityJSON = json["authority"] as? [String: Any],
              let authority = RequestAuthorityVersion(validatedJSON: authorityJSON) else { return nil }
        self.init(fields: json, authority: authority)
    }

    public init?(json: [String: Any]) {
        guard let idValue = json["id"], WireProtocol.validate(.requestID, value: idValue),
              let admissionDeadlineValue = json["admissionDeadline"],
              WireProtocol.validate(.positiveInteger, value: admissionDeadlineValue) else { return nil }
        self.init(fields: json, authority: RequestAuthorityVersion(rawValue: json["authority"]))
    }

    private init?(fields json: [String: Any], authority: RequestAuthorityVersion?) {
        guard let id = json["id"] as? Int,
              let name = json["name"] as? String,
              let jsonBody = json["body"] as? [String: Any],
              let providerValue = json["provider"] as? String,
              let provider = InpageProvider(rawValue: providerValue),
              provider != .multiple,
              let host = json["host"] as? String,
              let configurationKey = json["configurationKey"] as? String,
              let enqueueAttempt = json["enqueueAttempt"] as? String,
              let admissionDeadlineMilliseconds = json["admissionDeadline"] as? Int,
              let workflowVersion = json["workflowVersion"] as? Int
        else { return nil }
        
        self.id = id
        self.name = name
        self.host = host
        self.configurationKey = configurationKey
        self.enqueueAttempt = enqueueAttempt
        self.admissionDeadlineMilliseconds = admissionDeadlineMilliseconds
        self.workflowVersion = workflowVersion
        self.authority = authority
        authorizedAccount = nil
        
        self.provider = provider
        
        guard let body = Body(provider: provider, name: name, json: jsonBody) else { return nil }
        self.body = body
    }

}
