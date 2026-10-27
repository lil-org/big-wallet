import WalletAuthority
@MainActor func forbidden(_ wallets: WalletsManager) async throws { _ = try await wallets.addWallet(input: "fixture", inputPassword: nil) }
