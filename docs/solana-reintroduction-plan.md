# Solana Reintroduction Plan (Recovery-Driven)

Last updated: 2026-03-18
Owner: wallet/safari-extension
Status: Draft for iteration

## Goal

Reintroduce Solana support in Safari extension and native app flows by reusing previously working implementation artifacts, while adapting to current project structure and avoiding blind copy-paste regressions.

## Key Findings

### 1) Solana removal happened in phases, not one commit

1. `97dd12f6` (2023-10-17, "update pods and cleanup")
- Removed runtime Solana service (`Shared/Services/Solana.swift`).
- Removed Solana and Near branches from `Shared/Services/DappRequestProcessor.swift`.

2. `8f28f835` (2023-10-17, "disable near and solana")
- Disabled multi-coin default derivations in `Shared/Wallets/CoinDerivation.swift`.

3. `0aae2de7` (2023-10-17, "disable near and solana providers")
- Commented out Solana/Near injection in inpage provider wiring.

4. `79c42a2e` (2023-10-26, "remove near and solana providers for now")
- Deleted inpage provider files (`Safari Shared/web3-provider/solana.js`, `near.js`).
- Removed `bs58` dependency from provider package.

5. `2a06b41a` (2023-10-26, "clean up near and solana")
- Deleted Safari request/response Solana models.
- Removed Solana enum cases/mapping in provider and request/response routing layers.

6. Later cleanups (post-removal)
- `f970eba6` removed `CoinDerivation` model entirely (2023-12-05).
- `ca095c20` removed Solana logo assets (2023-12-05).

### 2) Best full recovery snapshot

Use commit `8d30ff34` (parent of `97dd12f6`) as the best "last complete Solana support" snapshot before removal cascade.

Why this commit is the best baseline:
- It contains full Safari Solana provider JS + routing.
- It contains Solana request/response Swift models.
- It contains app-side Solana request processing in `DappRequestProcessor`.
- It contains native `Shared/Services/Solana.swift` signing/send logic.
- It includes multi-coin wallet derivation plumbing from that era.

### 3) Extracted artifact bundle

A local extraction bundle was generated for analysis:
- `/tmp/solana-recovery-8d30ff34`

Contains:
- `Safari_Shared/web3-provider/solana.js`
- `Safari_Shared/web3-provider/index.js`
- `Safari_Shared/Models/Requests/SolanaSafariRequest.swift`
- `Safari_Shared/Models/Responses/SolanaResponseToExtension.swift`
- `Shared/Services/Solana.swift`
- `Shared/Services/DappRequestProcessor.swift`
- `Shared/Wallets/CoinDerivation.swift`
- `Shared/Wallets/WalletsManager.swift`
- and related routing/mapping files.

Note: `/tmp` is not guaranteed permanent. Re-extract via `git show` when needed.

## Most Valuable Legacy Artifacts to Reuse

## A) Inpage Solana provider behavior

Source:
- `8d30ff34:Safari Shared/web3-provider/solana.js`

Valuable features:
- `connect`, `signMessage`, `signTransaction`, `signAllTransactions`, `signAndSendTransaction`.
- Phantom compatibility surface (`isPhantom`, `window.phantom.solana`).
- `onlyIfTrusted` handling in `connect`.
- Proper response mapping for signed txs (`transaction.addSignature(...)`).
- `accountChanged` emission on switch-account responses.
- Support for both single and batch transaction signing flows.

## B) Extension multi-provider dispatch wiring

Source:
- `8d30ff34:Safari Shared/web3-provider/index.js`

Valuable features:
- Provider-specific response dispatch (`deliverResponseToSpecificProvider`).
- `didLoadLatestConfiguration` fan-out to each provider.
- Multi-provider disconnect signaling (`providersToDisconnect`).

## C) Safari request/response contract for Solana

Sources:
- `8d30ff34:Safari Shared/Models/Requests/SolanaSafariRequest.swift`
- `8d30ff34:Safari Shared/Models/Responses/SolanaResponseToExtension.swift`

Valuable features:
- Minimal payload model with `publicKey`, `message/messages`, `displayHex`, `sendOptions`.
- Response model covering `publicKey`, `result`, `results`.
- Explicit marker for whether response should update stored configuration.

## D) App request processor Solana flow

Source:
- `8d30ff34:Shared/Services/DappRequestProcessor.swift`

Valuable features:
- Solana connect path with account selection (`coinType: .solana`).
- Signing/sign-and-send paths integrated with approval UX.
- `switchAccount` mixed-provider response composition.

## E) Native Solana signing and send service

Source:
- `8d30ff34:Shared/Services/Solana.swift`

Valuable features:
- Message signing using `CoinType.solana.curve` + Base58 output.
- `signAndSendTransaction` retry logic with blockhash refresh.
- Transaction data compilation helper for signed payloads.

## Historical hardening commits worth mining

1. `cff5fe2e`: `onlyIfTrusted` connect behavior.
2. `53ed1ed4`: account-changed emission semantics.
3. `15b2873e`, `1432d534`, `f3ff21a7`: disconnect handling fixes.
4. `ce29a4f1`: explicit private key flow into Solana service.
5. `57c3ba0c`: retry loop correctness on transaction send.
6. `c0cfc976`: UX guard for non-Ethereum network selector behavior.

## Mapping Old Structure to Current Structure

Old paths/names used in legacy artifacts differ from current project.

1. Provider enum
- Old: `Web3Provider`
- Current: `InpageProvider`

2. Inpage provider source folder
- Old: `Safari Shared/web3-provider/`
- Current: `Safari Shared/Inpage Provider/`

3. JS namespace names
- Old: `window.tokenary`, `TokenaryEthereum`, `TokenarySolana`
- Current: `window.bigwallet`, `BigWalletEthereum`

4. Wallet model
- Old: `TokenaryWallet` + `CoinDerivation`
- Current: `WalletContainer` (no `CoinDerivation` model)

5. Coin mapping extension path
- Old: `Shared/Extension/CoinType.swift`
- Current: `Shared/Extensions/CoinType.swift`

## Reintroduction Workstreams (Issue-Driven, No Timeline)

## Workstream 0: Mandatory decisions before implementation

These decisions are required to avoid ambiguous behavior and security regressions.

1. Address matching policy by coin:
- Ethereum: case-insensitive matching allowed.
- Solana: exact-case matching only.
- Add a single address comparison helper and route all wallet/account lookups through it.

2. Wallet support policy:
- Decide exact Solana behavior for mnemonic wallets vs private-key wallets.
- Explicitly document whether importing a raw Solana private key is in scope.
- Explicitly document behavior for existing Ethereum-only private-key wallets when Solana is requested.

3. Mobile confirmation policy:
- Decide whether Solana `connect` must require the same confirmation level as Ethereum `requestAccounts`.
- Apply this policy in both `content.js` request gating rules and `service_worker.js` mobile confirm/navigation handling.

4. Solana send strategy:
- Decide whether to keep legacy custom `signAndSendTransaction` implementation or adapt to current architecture.
- Decide supported Solana transaction formats for v1 (legacy only vs legacy + versioned).

5. Solana RPC ownership policy:
- Decide which cluster/environment owns Solana send flows in v1.
- Decide whether endpoint selection is fixed, bundled configuration, or user/network driven.
- Ensure `signAndSendTransaction` does not silently inherit the legacy hardcoded mainnet-beta RPC behavior.

Exit criteria:
- These decisions are documented in this file and treated as implementation constraints.

### Decision Log (must be filled before implementation starts)

1. Address matching policy by coin
- Status: pending
- Owner: _unassigned_
- Decision: _TBD_

2. Wallet support policy (mnemonic vs private-key behavior)
- Status: pending
- Owner: _unassigned_
- Decision: _TBD_

3. Mobile confirmation policy for Solana `connect`
- Status: pending
- Owner: _unassigned_
- Decision: _TBD_

4. Solana send strategy and transaction-format scope
- Status: pending
- Owner: _unassigned_
- Decision: _TBD_

5. Solana RPC ownership policy
- Status: pending
- Owner: _unassigned_
- Decision: _TBD_

## Workstream 1: Provider/type contract restoration

Goal: restore full Solana request/response parsing and provider mapping, without runtime signing yet.

Tasks:
1. Add `solana` to `InpageProvider` and all related enum/mapper switches.
2. Extend `SafariRequest.Body` to parse Solana payloads.
3. Reintroduce Solana request/response model types under current folder scheme.
4. Extend `ResponseToExtension.Body` for Solana responses.
5. Extend `UnknownSafariRequest` provider-configuration parsing so `switchAccount` can preserve Solana state.
6. Extend `CoinType` <-> `InpageProvider` mapping for Solana.

Safety constraints:
- No `fatalError` in provider-routing or mapping paths for user-driven flows.
- Unknown provider data must degrade gracefully, not crash or silently corrupt state.

Exit criteria:
- Solana request parse/serialize works end-to-end.
- `switchAccount` configuration can carry Ethereum + Solana entries together.

## Workstream 2: Inpage provider and JS routing reintroduction

Goal: restore Solana inpage API surface and provider-specific response routing.

Tasks:
1. Port legacy `solana.js` behavior into `Safari Shared/Inpage Provider/` with current naming (`BigWallet*`).
2. Wire `index.js` to:
- initialize Solana provider,
- fan out `didLoadLatestConfiguration` to both Ethereum and Solana,
- route disconnect events per provider,
- route unknown-provider responses only for bootstrap/config synchronization events, not for arbitrary RPC results.
3. Reintroduce `bs58` dependency in inpage package.
4. Rebuild generated `Safari Shared/Resources/inpage.js`.
5. Define and preserve error contract compatibility for Solana provider flows:
- user rejection/cancel errors,
- unauthorized/provider-not-ready behavior,
- unsupported method behavior,
- malformed payload behavior.

Safety constraints:
- Keep compatibility surfaces required by dapps (`window.solana`, `window.phantom.solana`) explicit.
- Keep `onlyIfTrusted` behavior deterministic and testable.
- Error codes and shapes must remain stable and provider-compatible across reconnect/disconnect cycles.

Exit criteria:
- Solana provider is available on page and can send/receive bridge messages reliably.
- No regression in Ethereum provider initialization and routing.

## Workstream 3: Native request processing and action-model decoupling

Goal: add Solana runtime handling without relying on Ethereum-only assumptions.

Tasks:
1. Restore Solana request handling in `DappRequestProcessor`:
- `connect`
- `signMessage`
- `signTransaction`
- `signAllTransactions`
- `signAndSendTransaction`
2. Reintroduce/port `Shared/Services/Solana.swift` with current architecture constraints.
3. Remove Ethereum-only assumptions in `switchAccount` response composition.
4. Refactor action contracts where needed so non-EVM flows do not depend on `EthereumNetwork` semantics.
5. Ensure approval UX selection paths do not force Ethereum defaults into Solana-only flows.
6. Define Solana approval/auth mapping explicitly:
- which Solana methods map to `signMessage` vs `approveTransaction` subjects,
- which authentication reason/title each method uses,
- required metadata rendering rules per method.
7. Validate persisted configuration safety:
- sanitize provider configuration loaded from extension storage,
- ignore or migrate malformed/stale entries without crashing,
- ensure per-provider storage updates do not overwrite unrelated provider state.

Safety constraints:
- No runtime `fatalError` on Solana or mixed-provider account selections.
- Mixed Ethereum+Solana `switchAccount` must produce provider-correct bodies and disconnect sets.
- Configuration parsing/storage errors must fail closed and preserve existing valid provider state.

Exit criteria:
- Each Solana method reaches approval and returns correct response schema.
- `switchAccount` works for Ethereum-only, Solana-only, and mixed-provider selections.

## Workstream 4: Wallet/account availability, persistence, and safe lookup

Goal: make Solana account retrieval reliable and safe across new and existing wallets without losing Solana-capable state during wallet create/import/update flows.

Tasks:
1. Update wallet/account lookup logic to use coin-aware address comparison.
2. Ensure `getSpecificAccount`, `getWalletAndAccount`, and private-key retrieval paths respect Solana case sensitivity.
3. Implement chosen account-availability strategy:
- lazy derivation, default derivation, or hybrid for mnemonic wallets.
4. Implement explicit behavior for private-key wallets based on Workstream 0 decision.
5. Update wallet create/import paths so Solana-capable mnemonic and private-key wallets are persisted under the chosen policy rather than implicitly remaining Ethereum-only.
6. Update wallet maintenance flows so Solana account derivations survive save/update/re-encryption paths:
- password change,
- wallet rename/update,
- enable/disable account edits,
- load/save round-trips from keychain.
7. Update account preview/suggestion helpers so Solana account availability does not depend on Ethereum `defaultCoin` assumptions.
8. Validate create/import/update/edit-account flows after Solana addition, including mnemonic preview, account enablement, and post-update wallet recovery.

Safety constraints:
- Never sign for a Solana address that matches only after lowercasing.
- Failing lookup must return controlled errors, not fallback to wrong accounts.
- Wallet update/re-encryption paths must not silently drop non-Ethereum derivations or make Solana accounts undiscoverable after app restart.

Exit criteria:
- `suggestedAccounts(coin: .solana)` works for supported wallet types.
- Existing wallets behave predictably under documented policy.
- Solana-capable wallets retain expected accounts after import, app restart, account edits, and password-change/update flows.

## Workstream 5: UX behavior alignment

Goal: preserve current UX quality while adding Solana-specific behavior where required.

Tasks:
1. Preserve non-EVM network-selector guard behavior on iOS/macOS account selection.
2. Apply chosen mobile confirmation policy for Solana connect flows across both `content.js` gating and `service_worker.js` confirm/navigation UX.
3. Validate approval metadata rendering for Solana message/transaction flows.
4. Validate provider disconnect and account-change event behavior from JS to native and back.
5. Define and implement explicit default preselection behavior for `switchAccount` when stored provider configuration is empty, stale, or partially invalid:
- do not rely on Ethereum `defaultCoin` fallback behavior,
- make mixed-provider extension-button and first-run flows deterministic,
- preserve existing valid provider selections while recovering from malformed entries.

Exit criteria:
- No Ethereum UX regression.
- Solana flows present coherent account identity, metadata, and disconnect behavior.
- Empty or malformed mixed-provider configuration no longer causes `switchAccount` preselection to default implicitly to Ethereum.

## Workstream 6: Validation and regression coverage

Goal: add enough verification to prevent silent regressions during reintroduction.

Required checks:
1. Connect/disconnect across iOS + macOS Safari extension.
2. `connect({ onlyIfTrusted: true })` behavior.
3. Sign message (hex/text display handling).
4. Sign transaction and sign all transactions.
5. Sign and send transaction (including blockhash-not-found retry path if retained).
6. Switch account with mixed provider state and provider-specific disconnects.
7. Coin-aware address matching tests (Ethereum case-insensitive, Solana exact-case).
8. Parser/serializer tests for Solana request and response contracts.
9. Negative-path tests:
- user cancels approval/connect,
- provider not ready / unauthorized paths,
- unsupported method handling,
- malformed payload handling,
- callback/pending-request cleanup after failures and timeouts.
10. Configuration persistence tests:
- mixed-provider configuration merge behavior,
- malformed stored entries are ignored/migrated safely,
- disconnect removes only targeted provider configuration.
11. Wallet lifecycle and migration tests:
- create/import for supported Solana wallet types,
- password-change/update flows preserve Solana derivations,
- account preview/suggestion behavior does not regress to Ethereum-only defaults.
12. Solana send ownership tests:
- selected RPC cluster/endpoint policy is applied consistently,
- no hidden fallback to legacy hardcoded mainnet-beta behavior.

Definition of done:
- Manual matrix passes.
- New automated coverage exists for the non-trivial parser/routing/address-matching logic.

## Risks and Pitfalls

1. Coin-agnostic lowercase address matching can create unsafe Solana account resolution/signing paths.
2. Ethereum-only assumptions in current action/routing logic can crash mixed-provider flows if not removed.
3. Mobile confirmation behavior currently tuned for Ethereum can produce unintended Solana connect UX.
4. Wallet derivation/import behavior changed significantly; explicit mnemonic vs private-key policy is required.
5. Legacy Solana send/sign logic may not match current architecture or supported transaction formats.
6. Leaving Solana RPC ownership implicit can accidentally reintroduce legacy hardcoded mainnet-beta sends.
7. Generated `inpage.js` can drift from source if rebuild is skipped.
8. Blindly restoring old names/events can mismatch current bridge contracts and break provider expectations.

## Suggested starting point for implementation

Use `8d30ff34` artifacts as reference, but port into current paths and naming:
- Keep modern `InpageProvider`/`BigWallet` naming.
- Keep current extension bridge contract.
- Re-implement Solana feature slices incrementally behind clear checks.

## Appendix: Useful git anchors

- Full pre-removal baseline: `8d30ff34ae5c2bd9a55170c3b1804c9c38172321`
- Removal sequence:
  - `97dd12f6d33711abdc78e329c8f6c985fae2e421`
  - `8f28f8353986f915d7cb44c92d31f26272a96733`
  - `0aae2de77db84da80a5a13bae740ed82174460bd`
  - `79c42a2e5252ffb04def69438faa8b6f0dfe9c48`
  - `2a06b41aaddae4c05d2ca4f27629ffb65783b98f`

- Hardening/behavior commits:
  - `cff5fe2e` (`onlyIfTrusted`)
  - `53ed1ed4` (`accountChanged`)
  - `15b2873e`, `1432d534`, `f3ff21a7` (disconnect)
  - `ce29a4f1`, `57c3ba0c` (send/sign reliability)
  - `c0cfc976` (non-EVM selector UX guard)
