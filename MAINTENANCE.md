# maintenance

Manual operational checklist. Release gates and recurring checks both live here; walk through this list from time to time.

## re-probe fee-market hints

Every catalog network carries a `feeMarketHint` with the date it was last checked (`checkedAt`). Hints never expire in the app, so they are only as good as the last probe.

```bash
cd Workers/alchemy-jwt && npm run probe:fee-markets -- --expected-kid KID --output /tmp/fee-market-candidate.json
```

`--output` requires Alchemy authorization for this catalog, so `--expected-kid` must be provided and `ALCHEMY_JWT_REQUEST_PROOF_KEY` must be available from the environment or login Keychain; the output path must not already exist. Diff the candidate against `Shared/Ethereum/NetworkCatalog.json` and apply it explicitly after reviewing the complete change. The probe never touches the source catalog. Details: `Workers/alchemy-jwt/README.md`, "Fee-market catalog probe".

## keep the network catalog and ownership set in lockstep

When adding or removing chains, update `Shared/Ethereum/NetworkCatalog.json` and `BundledNetworkOwnership.chainIds` (`Shared/Ethereum/NetworkCatalog.swift`) together. A mismatch trips the ownership kill-switch and disables the entire bundled catalog at runtime.

## before a release

- The macOS approval helper belongs inside `Safari macOS.appex/Contents/Helpers/Big Wallet.app`. Safari's native-extension sandbox can deny access to a sibling helper under the containing app's `Contents/Helpers`, including in Xcode's DerivedData; builds must remove the old outer helper copies.
- Bump the version: `Scripts/asc/bump.sh` (commit as `bump version to X.Y.Z (build)`).
- Validate localizations: `Scripts/asc/validate_localizations.sh`.
- Before a macOS or aggregate release, file the required Feedback Assistant report. Replace `PENDING` in `app-store-connect/macos-app-sandbox-feedback-id.txt` with its exact `FB` number and commit that reviewed change. Then set `feedback_id="$(<app-store-connect/macos-app-sandbox-feedback-id.txt)"` and enter this App Sandbox Information in App Store Connect, replacing `TRACKED_FEEDBACK_ID` with `$feedback_id`:

  ```text
  Entitlement key: com.apple.security.temporary-exception.apple-events
  Usage information: Big Wallet's Safari Web Extension sends Apple events only to the separately signed, embedded approval helper whose bundle identifier is org.lil.wallet.ambient. App Sandbox otherwise prevents the extension from delivering a pending wallet route to an already-running helper or asking an incompatible helper instance to quit. This enables the extension toolbar and websites in Safari to open the wallet approval UI and receive the resulting approval or rejection. To assess it, install the macOS build, enable Big Wallet in Safari, open a test dapp, request a wallet connection or signature, and approve or reject it in the Big Wallet window; also click the extension toolbar and switch accounts. The only array value, org.lil.wallet.ambient, identifies that embedded helper. Feedback Assistant: TRACKED_FEEDBACK_ID.
  ```

  With that unexported `feedback_id` shell variable, run one command:
  - macOS only: `ASC_MACOS_APP_SANDBOX_FEEDBACK_ID="$feedback_id" ASC_MACOS_APP_SANDBOX_INFORMATION_CONFIRMED=org.lil.wallet.ambient asc workflow run release_macos`
  - All platforms: `ASC_MACOS_APP_SANDBOX_FEEDBACK_ID="$feedback_id" ASC_MACOS_APP_SANDBOX_INFORMATION_CONFIRMED=org.lil.wallet.ambient asc workflow run release`

  Do not export or otherwise persist either confirmation value.

## alchemy jwt worker

- Release/verify loop: local suite → upload → rollout → verify, per `Workers/alchemy-jwt/README.md` ("First HMAC production rollout" and "Future HMAC-compatible Worker updates").
- After a signing-key rotation, respect the retirement window before removing the old public key, and mind the request-proof-key fingerprint caveat (`Scripts/alchemy_jwt_request_proof_key.sha256`). Details in the Worker README.
