# Tokenary
Crypto wallet with Safari extension.

## Development

Required

- CocoaPods
- Node.js (`brew install node`)
- Yarn (`brew install yarn`)

Steps:

1. Run `pod install`
2. In `Safari-Shared/web3-provider` run `npm install`
3. Create `Shared/Supporting Files/Secrets.swift` with the following contents
   ```swift
   struct Secrets {
       static let infura = "YOUR INFURA PROJECT ID HERE"
   }
   ```
