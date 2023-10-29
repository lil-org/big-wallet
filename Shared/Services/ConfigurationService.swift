// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

class ConfigurationService {
    
    var shouldUpdateApp = false // TODO: implement with defaults
    
    private struct ConfigurationResponse: Codable {
        let shouldUpdateApp: Bool
    }
    
    static let shared = ConfigurationService()
    private init() {}
    
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .ephemeral)
        
    func check() {
        getConfiguration()
    }
    
    private func getConfiguration() {
        let url = URL(string: "https://tokenary.io/t-app-configuration")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            if let data = data, let configuration = try? self?.jsonDecoder.decode(ConfigurationResponse.self, from: data) {
                guard configuration.shouldUpdateApp else { return }
                DispatchQueue.main.async { self?.shouldUpdateApp = true }
            }
        }
        dataTask.resume()
    }
    
}
