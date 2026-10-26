import WalletAuthority

func forbidden(credentials: WalletCredentials) throws {
    _ = try credentials.readPasswordData()
}
