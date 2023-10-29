// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import CoreTelephony
import Network

class NetworkMonitor {
    
    var hasConnection = true
    static let shared = NetworkMonitor()
    
    private let nwPathMonitor = NWPathMonitor()
    private init() {}
    
    func start() {
        let queue = DispatchQueue(label: "NetworkMonitor")
        nwPathMonitor.start(queue: queue)
        nwPathMonitor.pathUpdateHandler = { [weak self] path in
            let hasConnectionNow = path.status == .satisfied
            if self?.hasConnection != hasConnectionNow {
                DispatchQueue.main.async {
                    self?.hasConnection = hasConnectionNow
                    if hasConnectionNow {
                        NotificationCenter.default.post(name: .connectionAppeared, object: nil)
                    }
                }
            }
        }
    }
    
}
