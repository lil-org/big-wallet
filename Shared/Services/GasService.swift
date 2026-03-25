// ∅ 2026 lil org

import Foundation

class GasService {
    
    struct Info {
        // Keep these values in wei so they stay comparable with Transaction.gasPrice.
        let standard: UInt
        let slow: UInt
        let fast: UInt
        let rapid: UInt
        
        var sortedValues: [UInt] {
            return Set([slow, standard, fast, rapid]).sorted()
        }
    }
    
    private struct Message: Decodable {
        let unit: String
        let blockPrices: [BlockPrice]
        
        struct BlockPrice: Decodable {
            let baseFeePerGas: Decimal?
            let estimatedPrices: [EstimatedPrice]
        }
        
        struct EstimatedPrice: Decodable {
            let confidence: Int
            let price: Decimal?
            let maxPriorityFeePerGas: Decimal?
            
            func legacyPriceWei(baseFeePerGas: Decimal?) -> UInt? {
                if let price = price, let priceWei = Self.wei(fromGwei: price) {
                    return priceWei
                }
                guard let baseFeePerGas, let maxPriorityFeePerGas else { return nil }
                return Self.wei(fromGwei: baseFeePerGas + maxPriorityFeePerGas)
            }
            
            func preciseLegacyPriceWei(baseFeePerGas: Decimal?) -> UInt? {
                guard let baseFeePerGas, let maxPriorityFeePerGas else { return nil }
                return Self.wei(fromGwei: baseFeePerGas + maxPriorityFeePerGas)
            }
            
            private static func wei(fromGwei gwei: Decimal) -> UInt? {
                let decimal = NSDecimalNumber(decimal: gwei).multiplying(byPowerOf10: 9)
                let rounding = NSDecimalNumberHandler(roundingMode: .up,
                                                      scale: 0,
                                                      raiseOnExactness: false,
                                                      raiseOnOverflow: false,
                                                      raiseOnUnderflow: false,
                                                      raiseOnDivideByZero: false)
                let rounded = decimal.rounding(accordingToBehavior: rounding)
                guard rounded != NSDecimalNumber.notANumber else { return nil }
                return UInt(rounded.stringValue)
            }
        }
        
        private enum Tier: CaseIterable {
            case slow
            case standard
            case fast
            case rapid
            
            var confidenceLevel: Int {
                switch self {
                case .slow:
                    return 70
                case .standard:
                    return 80
                case .fast:
                    return 90
                case .rapid:
                    return 99
                }
            }
        }
        
        var info: Info? {
            guard unit.lowercased() == "gwei",
                  let blockPrice = blockPrices.first(where: { !$0.estimatedPrices.isEmpty }) else { return nil }
            
            let exactConfidenceMap = Dictionary(uniqueKeysWithValues: blockPrice.estimatedPrices.map { ($0.confidence, $0) })
            let fallbackOrderedPrices = blockPrice.estimatedPrices.sorted(by: { $0.confidence < $1.confidence })
            
            func estimate(for tier: Tier) -> EstimatedPrice? {
                if let exactMatch = exactConfidenceMap[tier.confidenceLevel] {
                    return exactMatch
                }
                
                return fallbackOrderedPrices.min { lhs, rhs in
                    let lhsDistance = abs(lhs.confidence - tier.confidenceLevel)
                    let rhsDistance = abs(rhs.confidence - tier.confidenceLevel)
                    if lhsDistance == rhsDistance {
                        return lhs.confidence > rhs.confidence
                    } else {
                        return lhsDistance < rhsDistance
                    }
                }
            }
            
            let selectedEstimates = Tier.allCases.compactMap { tier in
                estimate(for: tier).map { (tier, $0) }
            }
            guard selectedEstimates.count == Tier.allCases.count else { return nil }
            
            let primaryValues = Dictionary(uniqueKeysWithValues: selectedEstimates.compactMap { tier, estimate in
                estimate.legacyPriceWei(baseFeePerGas: blockPrice.baseFeePerGas).map { (tier, $0) }
            })
            let preciseValues = Dictionary(uniqueKeysWithValues: selectedEstimates.compactMap { tier, estimate in
                estimate.preciseLegacyPriceWei(baseFeePerGas: blockPrice.baseFeePerGas).map { (tier, $0) }
            })
            
            let values: [Tier: UInt]
            let allTierCount = Tier.allCases.count
            let primaryDistinctCount = Set(primaryValues.values).count
            let preciseDistinctCount = Set(preciseValues.values).count
            if primaryValues.count == allTierCount,
               (primaryDistinctCount == allTierCount || primaryDistinctCount >= preciseDistinctCount) {
                values = primaryValues
            } else {
                // Blocknative's documented legacy `price` field can be rounded enough that
                // multiple confidence levels collapse into one slider tick. Preserve distinct
                // legacy tiers with the precise base-fee-plus-tip calculation when needed.
                values = preciseValues
            }
            
            guard let slow = values[.slow],
                  let standard = values[.standard],
                  let fast = values[.fast],
                  let rapid = values[.rapid],
                  Set(values.values).count > 1 else { return nil }
            
            return Info(standard: standard, slow: slow, fast: fast, rapid: rapid)
        }
    }
    
    static let shared = GasService()
    
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .default)
    
    private init() {}
    
    var currentInfo: Info?
    
    func start() {
        getMessage()
    }
    
    private func getMessage() {
        let url = URL(string: "https://api.blocknative.com/gasprices/blockprices?chainid=1&confidenceLevels=70,80,90,99")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            guard let self else { return }
            if let data = data,
               let message = try? jsonDecoder.decode(Message.self, from: data),
               let info = message.info {
                DispatchQueue.main.async {
                    self.currentInfo = info
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(30)) {
                self.getMessage()
            }
        }
        dataTask.resume()
    }
    
}
