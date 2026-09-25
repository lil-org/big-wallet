# maintenance

Manual operational checklist. Release gates and recurring checks both live here; walk through this list from time to time.

## when testing Safari builds from multiple worktrees

Check `pluginkit -m -A -D -v -i org.lil.wallet.Safari` before diagnosing a Safari regression. Different worktrees can register different extension code with the same bundle identifier and build number. Safari can retain the old JavaScript worker while native messaging reaches the current build.

Unregister the exact stale `.appex` path with `pluginkit -r`, then register the intended `.appex` with `pluginkit -a`. Keep the build files and wallet data. Stop stale debug helpers with `Scripts/terminate_ambient_agents.sh`, setting `CONFIGURATION=Debug` and both build-directory variables to that stale build's products directory. Confirm the loaded worker source in Safari's Develop → Web Extension Background Content inspector; the native process path alone is insufficient.

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
- Before submitting a new macOS version for review, file the required Feedback Assistant report. Replace `PENDING` in `app-store-connect/macos-app-sandbox-feedback-id.txt` with its exact `FB` number and commit that reviewed change. Enter this App Sandbox Information in App Store Connect, replacing `TRACKED_FEEDBACK_ID` with the ID from that file:

  ```text
  Entitlement key: com.apple.security.temporary-exception.apple-events
  Usage information: Big Wallet's Safari Web Extension sends Apple events only to the separately signed, embedded approval helper whose bundle identifier is org.lil.wallet.ambient. App Sandbox otherwise prevents the extension from delivering a pending wallet route to an already-running helper or asking an incompatible helper instance to quit. This enables the extension toolbar and websites in Safari to open the wallet approval UI and receive the resulting approval or rejection. To assess it, install the macOS build, enable Big Wallet in Safari, open a test dapp, request a wallet connection or signature, and approve or reject it in the Big Wallet window; also click the extension toolbar and switch accounts. The only array value, org.lil.wallet.ambient, identifies that embedded helper. Feedback Assistant: TRACKED_FEEDBACK_ID.
  ```

  Run one command:
  - macOS only: `asc workflow run release_macos`
  - All platforms: `asc workflow run release`

  New macOS review submissions validate the tracked ID. Preflight, build upload, and already-submitted versions do not require it. App Sandbox Information must still be entered manually; the script does not verify App Store Connect metadata.

## alchemy jwt worker

- Release/verify loop: local suite → upload → rollout → verify, per `Workers/alchemy-jwt/README.md` ("First HMAC production rollout" and "Future HMAC-compatible Worker updates").
- After a signing-key rotation, respect the retirement window before removing the old public key, and mind the request-proof-key fingerprint caveat (`Scripts/alchemy_jwt_request_proof_key.sha256`). Details in the Worker README.
