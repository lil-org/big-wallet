// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import MultipeerConnectivity

private let serviceIdentifier = "connector"
private let queue = DispatchQueue(label: serviceIdentifier, qos: .default)

protocol NearbyConnectivityDelegate: AnyObject {
    func didFind(link: String)
}

class NearbyConnectivity: NSObject {
    
    private weak var connectivityDelegate: NearbyConnectivityDelegate?
    private var devicePeerID: MCPeerID!
    private var serviceBrowser: MCNearbyServiceBrowser!
    
    init(delegate: NearbyConnectivityDelegate) {
        super.init()
        connectivityDelegate = delegate
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
        guard let info = info, let link = info["wclink"] else { return }
        DispatchQueue.main.async { [weak connectivityDelegate] in
            connectivityDelegate?.didFind(link: link)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { }

}
