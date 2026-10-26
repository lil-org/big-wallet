import Foundation
import WalletDomain

public enum RuntimeTestCatalog {
    public static func load() throws -> NetworkCatalog {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle.main
#endif
        guard let url = bundle.url(forResource: NetworkCatalog.resourceName, withExtension: "json") else {
            throw NetworkCatalogLoadError.missingResource
        }
        return try NetworkCatalog(data: Data(contentsOf: url))
    }

    public static func resolver(
        customSnapshot: @escaping @Sendable () -> CustomNetworkSnapshot = { .empty },
        freshCustomSnapshot: (@Sendable () -> CustomNetworkSnapshotLoadResult)? = nil
    ) -> NetworkResolver {
        NetworkResolver(
            catalog: try? load(),
            catalogOwnedChainIds: BundledNetworkOwnership.chainIds,
            customSnapshot: customSnapshot,
            freshCustomSnapshot: freshCustomSnapshot
        )
    }
}
