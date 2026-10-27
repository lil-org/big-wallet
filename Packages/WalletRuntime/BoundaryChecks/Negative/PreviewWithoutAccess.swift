import WalletDomain
import WalletAuthority
@MainActor func forbidden(_ wallets: WalletsManager, _ wallet: WalletSnapshot) async throws { _ = try await wallets.previewSession(wallet: wallet) }
