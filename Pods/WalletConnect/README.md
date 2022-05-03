# WalletConnect

[![Codacy Badge](https://api.codacy.com/project/badge/Grade/44d202d68ed244878f955c03ad710f50)](https://www.codacy.com/app/TrustWallet/wallet-connect-swift?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=TrustWallet/wallet-connect-swift&amp;utm_campaign=Badge_Grade)
![CI](https://github.com/trustwallet/wallet-connect-swift/workflows/CI/badge.svg)

[WalletConnect](https://walletconnect.org/) Swift SDK, implements 1.0.0 websocket based protocol.

Demo video

<a href="https://www.youtube.com/watch?v=sFZzzNDLd8Y" ><img src="https://img.youtube.com/vi/sFZzzNDLd8Y/maxresdefault.jpg" width="90%"></a>

## Requirements

- iOS 11
- Xcode 10.2
- Swift 5

## Features

- [x] Connect and disconnect
- [x] Approve / Reject / Kill session
- [x] Approve and reject `eth_sign` / `personal_sign` / `eth_signTypedData`
- [x] Approve and reject `eth_signTransaction` / `eth_sendTransaction`
- [x] Approve and reject `bnb_sign` (binance dex orders)
- [x] session persistent / recovery

Todo:

- [ ] push notification (APNS)

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Installation

WalletConnect is available through [CocoaPods](https://cocoapods.org), [Carthage](https://github.com/Carthage/Carthage) and [Swift Package Manager](https://swift.org/package-manager/).

### CocoaPods

To install it, simply add the following line to your `Podfile`:

```ruby
pod 'WalletConnect', git: 'https://github.com/trustwallet/wallet-connect-swift', branch: 'master'
```

### Carthage

Add following line to your `Cartfile`:

```ruby
github "trustwallet/wallet-connect-swift"
```
### Swift Package Manager

Add `.package(url:_:)` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/trustwallet/wallet-connect-swift", .branch("master")),
],
```

## Usage

parse session from scanned QR code:

```swift
let string = "wc:..."
guard let session = WCSession.from(string: string) else {
    // invalid session
    return
}
// handle session
```

configure and handle incoming message:

```swift
let interactor = WCInteractor(session: session, meta: clientMeta)
interactor.onSessionRequest = { [weak self] (id, peer) in
    // ask for user consent
}

interactor.onDisconnect = { [weak self] (error) in
    // handle disconnect
}

interactor.eth.onSign = { [weak self] (id, payload) in
    // handle eth_sign, personal_sign, eth_signTypedData
}

interactor.eth.onTransaction = { [weak self] (id, event, transaction) in
    // handle eth_signTransaction / eth_sendTransaction
}

interactor.bnb.onSign = { [weak self] (id, order) in
    // handle bnb_sign
}
```

approve session

```swift
interactor.approveSession(accounts: accounts, chainId: chainId).done {
    print("<== approveSession done")
}.cauterize()
```

approve request

```swift
interactor.approveRequest(id: id, result: result.hexString).done {
    print("<== approveRequest done")
}.cauterize()
```

approve binance dex orders

```swift
interactor?.approveBnbOrder(id: id, signed: signed).done({ confirm in
    print("<== approveBnbOrder", confirm)
}).cauterize()
```

## Author

hewigovens

## License

WalletConnect is available under the MIT license. See the LICENSE file for more info.
