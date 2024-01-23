// ∅ 2024 lil org

import Foundation
import CloudKit

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
        getInfuraKeysFromCloudKit { infuraKeys in
            ExtensionBridge.defaultInfuraKeys = infuraKeys
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
    
    private func getInfuraKeysFromCloudKit(completion: @escaping ([String]) -> Void) {
        let container = CKContainer(identifier: "iCloud.tokenary")
        let publicDatabase = container.publicCloudDatabase
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "Config", predicate: predicate)
        publicDatabase.fetch(withQuery: query) { result in
            if case .success(let success) = result,
               case let .success(record) = success.matchResults.first?.1,
               let infuraKeys = record["infuraKeys"] as? [String], infuraKeys.first?.isEmpty == false {
                DispatchQueue.main.async {
                    completion(infuraKeys)
                }
            }
        }
    }
    
}
