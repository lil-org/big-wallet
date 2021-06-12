// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import MultipeerConnectivity

private let serviceIdentifier = "connector"
private let queue = DispatchQueue(label: serviceIdentifier, qos: .default)

class NearbyConnectivity: NSObject {
    
    private var devicePeerID: MCPeerID!
    private var serviceAdvertiser: MCNearbyServiceAdvertiser!
    private var serviceBrowser: MCNearbyServiceBrowser!
    
    init(link: String) {
        super.init()
        devicePeerID = MCPeerID(displayName: UUID().uuidString)
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: devicePeerID, discoveryInfo: ["wclink": link], serviceType: serviceIdentifier)
        serviceAdvertiser.delegate = self
        
        serviceBrowser = MCNearbyServiceBrowser(peer: devicePeerID, serviceType: serviceIdentifier)
        serviceBrowser.delegate = self
        
        autoConnect()
    }
    
    deinit {
        stopAdvertising()
        stopBrowsing()
    }
    
    private func stopAdvertising() {
        serviceAdvertiser.stopAdvertisingPeer()
    }
    
    private func stopBrowsing() {
        serviceBrowser.stopBrowsingForPeers()
    }
    
    private func autoConnect() {
        queue.async { [weak self] in
            self?.serviceBrowser.startBrowsingForPeers()
            self?.serviceAdvertiser.startAdvertisingPeer()
        }
    }
    
}

// MARK: - Advertiser Delegate
extension NearbyConnectivity: MCNearbyServiceAdvertiserDelegate {

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) { }

}

// MARK: - Browser Delegate
extension NearbyConnectivity: MCNearbyServiceBrowserDelegate {

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let info = info else { return }
        // TODO: use received info
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) { }

}
