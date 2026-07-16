// ∅ 2026 lil org

import Foundation

extension SafariRequest {
    
    struct Unknown: SafariRequestBody {
        
        enum Method: String {
            case justShowApp
            case switchAccount
        }
        
        struct ProviderConfiguration {
            let provider: InpageProvider
            let address: String?
            let chainId: String?
        }
        
        let method: Method
        let providerConfigurations: [ProviderConfiguration]
        
        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name) else { return nil }
            self.method = method
            
            var configurations = [ProviderConfiguration]()
            let jsonDecoder = JSONDecoder()
            if let latestConfigurations = json["latestConfigurations"] as? [[String: Any]] {
                for configuration in latestConfigurations {
                    guard let providerString = configuration["provider"] as? String,
                          let provider = InpageProvider(rawValue: providerString),
                          let data = try? JSONSerialization.data(withJSONObject: configuration)
                    else { continue }
                    
                    switch provider {
                    case .ethereum:
                        let response = try? jsonDecoder.decode(ResponseToExtension.Ethereum.self, from: data)
                        configurations.append(ProviderConfiguration(provider: provider,
                                                                     address: response?.results?.first,
                                                                     chainId: response?.chainId))
                    case .solana:
                        let response = try? jsonDecoder.decode(ResponseToExtension.Solana.self, from: data)
                        configurations.append(ProviderConfiguration(provider: provider,
                                                                     address: response?.publicKey,
                                                                     chainId: nil))
                    case .unknown, .multiple:
                        continue
                    }
                }
            }
            
            self.providerConfigurations = configurations
        }
        
        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .justShowApp:
                return false
            case .switchAccount:
                return true
            }
        }
        
    }
    
}
