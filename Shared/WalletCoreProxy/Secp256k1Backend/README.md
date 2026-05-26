// ∅ 2026 lil org

# secp256k1 backend

This directory vendors `bitcoin-core/secp256k1` at signed tag `v0.7.1`.

- Tag object: `833ca65c66b6e97b86489807103ca6e187ab25aa`
- Tagged commit: `1a53f4961f337b4d166c25fce72ef0dc88806618`
- Upstream: https://github.com/bitcoin-core/secp256k1

The app compiles `secp256k1/src/secp256k1.c`, its generated precomputed table
translation units, and `big_wallet_secp256k1_shim.c`. The recovery module is
enabled through the Xcode build flags for the vendored source.
