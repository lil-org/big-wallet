# Balance

Proof-of-concept EVM wallet with a Safari extension.

## Development

Required:

- CocoaPods
- Node.js (`brew install nodejs`)

Steps:

1. Install packages with CocoaPods:

- For M1 chips:
`arch -x86_64 pod install`

You may need to run:
`sudo arch -x86_64 gem install ffi`

and possibly:
`arch -x86_64 pod update`

- For other chips: `pod install`

2. In `Safari-Shared/web3-provider`, run `npm i` to install JavaScript dependencies

3. Create `Shared/Supporting Files/Secrets.swift` with the following contents:

```swift
enum Secrets {
    static let infura = "YOUR INFURA PROJECT ID HERE"
}
```

## License

[GPLv3](https://github.com/balance-io/Balance/blob/main/LICENSE)
