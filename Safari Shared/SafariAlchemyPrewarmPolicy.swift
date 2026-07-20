// ∅ 2026 lil org

enum SafariAlchemyPrewarmPolicy {

    static func allowsPrewarm(
        provider: InpageProvider?,
        chainId: String?
    ) -> Bool {
        switch provider {
        case .solana:
            return false
        case .ethereum, nil:
            guard let chainId,
                  let chainIdNumber = Int(hexString: chainId),
                  let network = Nodes.resolution(
                      chainId: chainIdNumber
                  ).resolvedNetwork else {
                return false
            }
            return network.allowsAlchemyAuthorization
        case .unknown, .multiple:
            return false
        }
    }

}
