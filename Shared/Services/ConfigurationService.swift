// ∅ 2024 lil org

import Foundation
import CloudKit

class ConfigurationService {
    
    static let shared = ConfigurationService()
    private init() {}
        
    func check() {
        getInfuraKeysFromCloudKit { infuraKeys in
            ExtensionBridge.defaultInfuraKeys = infuraKeys
        }
    }

    private func getInfuraKeysFromCloudKit(completion: @escaping ([String]) -> Void) {
        let container = CKContainer(identifier: "iCloud.org.lil.wallet")
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
