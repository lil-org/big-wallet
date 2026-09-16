// ∅ 2026 lil org

import Foundation

extension SafariRequest {
    
    struct Unknown {
        
        enum Method: String {
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
            if let latestConfigurations = json["latestConfigurations"] as? [[String: Any]] {
                for configuration in latestConfigurations {
                    guard let providerString = configuration["provider"] as? String,
                          let provider = InpageProvider(rawValue: providerString)
                    else { continue }
                    
                    switch provider {
                    case .ethereum:
                        configurations.append(ProviderConfiguration(provider: provider,
                                                                     address: (configuration["results"] as? [String])?.first,
                                                                     chainId: configuration["chainId"] as? String))
                    case .solana:
                        configurations.append(ProviderConfiguration(provider: provider,
                                                                     address: configuration["publicKey"] as? String,
                                                                     chainId: nil))
                    case .unknown, .multiple:
                        continue
                    }
                }
            }
            
            self.providerConfigurations = configurations
        }
    }
    
}
