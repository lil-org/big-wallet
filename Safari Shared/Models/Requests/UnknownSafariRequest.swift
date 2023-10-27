// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension SafariRequest {
    
    struct Unknown: SafariRequestBody {
        
        enum Method: String, Decodable, CaseIterable {
            case justShowApp
            case switchAccount
        }
        
        struct ProviderConfiguration {
            let provider: Web3Provider
            let address: String
            let network: EthereumNetwork?
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
                          let provider = Web3Provider(rawValue: providerString),
                          let data = try? JSONSerialization.data(withJSONObject: configuration)
                    else { continue }
                    
                    switch provider {
                    case .ethereum:
                        guard let response = try? jsonDecoder.decode(ResponseToExtension.Ethereum.self, from: data),
                              let address = response.results?.first else { continue }
                        configurations.append(ProviderConfiguration(provider: provider, address: address, network: EthereumNetwork.withChainId(response.chainId)))
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
