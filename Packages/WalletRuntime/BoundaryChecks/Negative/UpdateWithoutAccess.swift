import WalletDomain
import WalletAuthority
@MainActor func forbidden(_ wallets: WalletsManager, _ wallet: WalletSnapshot) async throws { try await wallets.update(wallet: wallet, enabledAccounts: []) }
