// ∅ 2024 lil org

import Foundation

let semaphore = DispatchSemaphore(value: 0)

let projectDir = FileManager.default.currentDirectoryPath
let base = "\(projectDir)/Tools/"

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
    
    let currentIds = Set(currentNetworks.keys)
    let newChainsIds = Set([810180])
    
    let newChains = chains.filter { chain in
        let isEIP3091 = chain.explorers?.contains(where: { $0.standard == "EIP3091" }) == true
        let allowNoEIP3091 = true
        if newChainsIds.contains(chain.chainId) &&
            !currentIds.contains(chain.chainId) &&
            chain.rpc.contains(where: { $0.hasPrefix(https) }) &&
            chain.redFlags == nil &&
            chain.status != "deprecated" &&
            chain.nativeCurrency.decimals == 18 &&
            (isEIP3091 || allowNoEIP3091) {
            return true
        } else {
            return false
        }
    }
    
    var updatedNetworks = currentNetworks
    var updatedNodes = currentNodes
    
    newChains.forEach { chain in
        updatedNetworks[chain.chainId] = BundledNetwork(name: chain.name,
                                                        symbol: chain.nativeCurrency.symbol,
                                                        isTest: true,
                                                        okToShowPriceForSymbol: false,
                                                        blockExplorer: chain.explorers?.first?.url)
        updatedNodes[String(chain.chainId)] = String(chain.rpc.first(where: { $0.hasPrefix(https) })!.dropFirst(https.count))
    }
    
    let data = (try! encoder.encode(updatedNetworks)) + "\n".data(using: .utf8)!
    try! data.write(to: bundledNetworksFileURL)
    updateNodesFiles(nodes: updatedNodes)
    semaphore.signal()
}

func updateNodesFiles(nodes: [String: String]) {
    let dictData = try! JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + "\n".data(using: .utf8)!
    try! dictData.write(to: nodesToBundleFileURL)
    
    let dictString = nodes.sorted(by: { Int($0.key)! < Int($1.key)! }).map { "\($0.key): \"\($0.value)\"" }.joined(separator: ",\n        ")
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
