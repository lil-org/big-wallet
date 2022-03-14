// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import CoreTelephony
import Network

// ToDo(@NumenZ) - Rewrite service using observable/observer pattern
//                  Values must be passed as sequences
// ToDo(@NumenZ) - Make a normal ServiceRegistry structure, to manage Singletons
public class NetworkMonitor {
    
    var hasConnection = true
    static let shared = NetworkMonitor()
    
    static let real = shared
    static let mock = shared
    
    private let nwPathMonitor = NWPathMonitor()
    init() {}
    
    func start() {
        let queue = DispatchQueue(label: "NetworkMonitor")
        nwPathMonitor.start(queue: queue)
        nwPathMonitor.pathUpdateHandler = { [weak self] path in
            let hasConnectionNow = path.status == .satisfied
            if self?.hasConnection != hasConnectionNow {
                DispatchQueue.main.async {
                    self?.hasConnection = hasConnectionNow
                    if hasConnectionNow {
                        NotificationCenter.default.post(name: Notification.Name.connectionAppeared, object: nil)
                    }
                }
            }
        }
    }
    
}
