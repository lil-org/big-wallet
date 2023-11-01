// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

let semaphore = DispatchSemaphore(value: 0)

let projectDir = FileManager.default.currentDirectoryPath
let base = "\(projectDir)/tools/"

let bundledNetworksFileURL = URL(fileURLWithPath: base + "bundled/bundled-networks.json")
let bundledNodesFileURL = URL(fileURLWithPath: base + "bundled/BundledNodes.swift")
let nodesToBundleFileURL = URL(fileURLWithPath: base + "helpers/nodes-to-bundle.json")

let https = "https://"

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]

func fetchChains(completion: @escaping ([EIP155ChainData]) -> Void) {
    URLSession.shared.dataTask(with: URL(string: "https://chainid.network/chains.json")!) { (data, _, _) in
        completion(try! JSONDecoder().decode([EIP155ChainData].self, from: data!))
    }.resume()
}

fetchChains { chains in
    let currentNetworksData = try! Data(contentsOf: bundledNetworksFileURL)
    let currentNodesData = try! Data(contentsOf: nodesToBundleFileURL)
    
    let currentNetworks = try! JSONDecoder().decode([Int: BundledNetwork].self, from: currentNetworksData)
    let currentNodes = try! JSONDecoder().decode([String: String].self, from: currentNodesData)
    let ids = Set(currentNetworks.keys)
    
    // TODO: make sure https
    let filtered = chains.filter { ids.contains($0.chainId) }
    
    var updatedNetworks = [Int: BundledNetwork]()
    let updatedNodes = currentNodes
    
    filtered.forEach { chain in
        updatedNetworks[chain.chainId] = BundledNetwork(name: chain.name, symbol: chain.nativeCurrency.symbol)
    }
    
    updatedNetworks = currentNetworks
    
    let data = (try! encoder.encode(updatedNetworks)) + "\n".data(using: .utf8)!
    try! data.write(to: bundledNetworksFileURL)
    updateNodesFiles(nodes: updatedNodes)
    semaphore.signal()
}

func updateNodesFiles(nodes: [String: String]) {
    let dictData = try! JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + "\n".data(using: .utf8)!
    try! dictData.write(to: nodesToBundleFileURL)
    
    let dictString = nodes.sorted(by: { Int($0.key)! < Int($1.key)! }).map { "\($0.key): \"\($0.value.dropFirst(https.count))\"" }.joined(separator: ",\n        ")
    let contents = """
    import Foundation

    struct BundledNodes {
        
        static let dict: [Int: String] = [
            \(dictString)
        ]
        
    }

    """
    
    try! contents.data(using: .utf8)?.write(to: bundledNodesFileURL)
}

semaphore.wait()
print("🟢 all done")
