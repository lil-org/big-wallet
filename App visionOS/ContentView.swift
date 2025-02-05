// ∅ 2025 lil org

import SwiftUI
import Kingfisher
import WalletCore
import BigInt

struct ContentView: View {
    var body: some View {
        VStack {
            Text(genRandomEthAddress())
        }
        .padding()
    }
}

func genRandomEthAddress() -> String {
    let password = ""
    let key = StoredKey(name: "", password: Data(password.utf8))
    let wallet = WalletContainer(id: "id", key: key)
    let account = try! wallet.getAccount(password: password, coin: .ethereum)
    return account.address
}
