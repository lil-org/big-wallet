// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import MultipeerConnectivity

private let serviceIdentifier = "connector"
private let queue = DispatchQueue(label: serviceIdentifier, qos: .default)

class NearbyConnectivity: NSObject {
    
    private var devicePeerID: MCPeerID!
    private var serviceBrowser: MCNearbyServiceBrowser!
    
    init(link: String) {
        super.init()
        devicePeerID = MCPeerID(displayName: UUID().uuidString)
        
        serviceBrowser = MCNearbyServiceBrowser(peer: devicePeerID, serviceType: serviceIdentifier)
        serviceBrowser.delegate = self
        
        autoConnect()
    }
    
    deinit {
        stopBrowsing()
    }
    
    private func stopBrowsing() {
        serviceBrowser.stopBrowsingForPeers()
    }
    
    private func autoConnect() {
        queue.async { [weak self] in
            self?.serviceBrowser.startBrowsingForPeers()
        }
    }
    
}

// MARK: - Browser Delegate
extension NearbyConnectivity: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let info = info else { return }
        // TODO: use received info
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { }

}
