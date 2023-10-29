// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

class ConfigurationService {
    
    var shouldPromptToUpdate: Bool {
        return shouldUpdateApp && !didPropmtToUpdate
    }
    
    private var shouldUpdateApp = Defaults.didReceiveShouldUpdateAppNotification
    private var didPropmtToUpdate = false
    
    private struct ConfigurationResponse: Codable {
        let shouldUpdateApp: Bool
    }
    
    static let shared = ConfigurationService()
    private init() {}
    
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .ephemeral)
        
    func check() {
        if !shouldUpdateApp {
            getConfiguration()
        }
    }
    
    func didPromptToUpdate() {
        didPropmtToUpdate = true
    }
    
    private func getConfiguration() {
        let url = URL(string: "https://tokenary.io/t-app-configuration")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            if let data = data, let configuration = try? self?.jsonDecoder.decode(ConfigurationResponse.self, from: data) {
                guard configuration.shouldUpdateApp else { return }
                DispatchQueue.main.async { 
                    Defaults.didReceiveShouldUpdateAppNotification = true
                    self?.shouldUpdateApp = true
                }
            }
        }
        dataTask.resume()
    }
    
}
