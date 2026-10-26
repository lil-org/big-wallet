import WalletDomain
import WalletAuthority
import WalletNetworking

extension SolanaClusterOptions {
    func description(for cluster: Solana.Cluster) -> String {
        var components = [
            cluster.displayName,
            cluster.rpcSource.displayName,
        ]
        if cluster == suggestedCluster {
            components.append(Strings.suggestedByWebsite)
        }
        return components.joined(separator: " - ")
    }
}

extension Solana.RPCSource {
        var displayName: String {
            switch self {
            case .alchemy:
                return Strings.alchemyRPC
            case .publicFallback:
                return Strings.publicRPC
            }
        }
}

extension TransactionReviewNotice {
    var title: String {
        switch self {
        case .preparationFailed(.unsafeFees), .unsafeFees: Strings.unsafeFees
        case .preparationFailed, .feesUnavailable: Strings.somethingWentWrong
        case .feesUpdated: Strings.feesUpdated
        }
    }

    var message: String? {
        switch self {
        case .preparationFailed(.unsafeFees), .unsafeFees: Strings.unsafeFeesEdit
        case .preparationFailed, .feesUnavailable: nil
        case .feesUpdated: Strings.feesUpdatedReview
        }
    }

}
