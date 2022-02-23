# Tokenary
Crypto wallet with Safari extension for iOS and macOS.

Download on the [App Store](https://tokenary.io/get).

## Development

Required

- CocoaPods
- Node.js (`brew install node`)
- Yarn (`brew install yarn`)

> How to build?

```bash
cd TOKENARY_PROJECT_PATH
export RBENV_VERSION=ruby-2.6.5
./scripts/0_setup.sh
./scripts/1_install.sh
```

Steps:

1. Run `pod install`
2. In `Safari-Shared/web3-provider` run `npm install`
3. Create `Shared/Supporting Files/Secrets.swift` with the following contents:
   ```swift
   struct Secrets {
       static let infura = "YOUR INFURA PROJECT ID HERE"
   }
   ```
