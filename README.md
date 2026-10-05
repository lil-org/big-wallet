# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

* run the xcode project
* recurring manual chores live in [MAINTENANCE.md](MAINTENANCE.md)

### Swift toolchain and concurrency

Use Xcode 27 or newer with Swift 6.4. All native targets use Swift 6 language mode. Minimum supported versions are iOS 26, macOS 15, and visionOS 2.

Default actor isolation is `nonisolated`, with `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` enabled. UI and wallet presentation state belong to `MainActor`; shared storage and service state use actors or `Synchronization.Mutex`. Unannotated async functions stay on their caller's actor, and CPU-intensive work uses `@concurrent`. Values crossing actors must be `Sendable`. Synchronous cancellation, secret invalidation, and lease release use synchronized ownership. File locks continue to coordinate the app, Safari extensions, and approval helper across processes. Never suspend while holding an in-process mutex.

Run `Scripts/check_swift6.sh` for the native Debug/Release builds, platform test suites, Safari protocol tests, Release crypto performance gates, and focused Thread Sanitizer checks. Individual stages are `build`, `test`, `performance`, and `tsan`. The script uses Xcode's default DerivedData, runs simulator suites serially, and disables coverage collection so sandboxed host profiling files are not required. Set `SWIFT6_IOS_DESTINATION` and `SWIFT6_VISIONOS_DESTINATION` to select installed simulator destinations. Runtime validation on the oldest supported OS versions requires those runtimes or devices separately.

### Safari wire protocol

`Safari Shared/Protocol/wire-protocol.json` defines the shared Swift and JavaScript wire contract. After editing it, run `node Scripts/generate_wire_protocol.mjs --write`, then `Scripts/build_inpage_provider.sh` to rebuild the page provider. Commit the definition and generated files together.

`Scripts/check_wire_protocol.sh` checks that the generated files are current without modifying them. Xcode builds, npm build/test commands, version bumps, and release preflight run this check. The generator uses Node.js built-ins and adds no package dependencies. `BUILD_VERSION` remains release metadata in `bridge_wire.js` and is updated by the existing version-bump script.

### Safari authorization

Ethereum `eth_sign` is unsupported and returns error `4200` without opening an approval. Use `personal_sign` or typed-data signing; there is no raw-signing opt-in or automatic conversion.

Native storage owns connected accounts, selected chains, and permission revisions, partitioned by Safari profile and origin. Permission changes and request results commit together. The extension validates Safari's sender metadata before relaying an origin; native messaging supplies the profile. Native storage does not independently attest a webpage's origin.

Claiming a request reserves ownership; it does not authorize privileged work. Accepting the current review produces process-local consent bound to the stored request and authority revisions. The store issues a one-use execution permit for account grants, signing, and new-network additions, and a separate dispatch permit only after a transaction broadcast checkpoint is durable. Stored responses and delivery receipts cannot recreate these capabilities. Ordinary completion is limited to failures, existing connections, address recovery, and known-chain selection.

A shared execution lifecycle owns the request lock and tracks preparation, authorization, execution, signing use, and broadcast dispatch. Claims capture the stored request binding and authorize directly; there is no intermediate reservation. Copied capabilities share consumption state, and cleanup from an old claim cannot release an approved execution. Consent consumption remains independent so a new claim cannot reuse an earlier acceptance.

Request preparation produces one immutable approval intent from a store-issued request binding. Review and execution use that same payload; execution refreshes account availability, network identity, and authority without rebuilding the approved request. The shared executor owns each acquired claim through authentication, preflight, authorization, completion, and cleanup.

Abandoning an execution releases its local ownership and uses the same recovery rules as a stopped process. Terminal publication receives one attempt; uncertain writes are observed or recovered without repeating privileged work. Interrupted popup approvals require explicit Retry, which builds a fresh review from the current request, account, and network and discards previous nonce and fee edits. Preflight warnings retain their correction controls without retaining execution authority.

Native consent receives one finalization attempt. Subsequent polling only observes the existing execution. Before execution is authorized, unavailable wallet or network data returns the request to explicit Retry on both native and popup approvals. Retry rebuilds the review and requires new consent without extending the request's original deadline. Confirmed account or network changes instead complete the request with the same provider error on both surfaces. Unexpected interruption and durable broadcast recovery retain their existing behavior; observation cannot reuse old consent or repeat dispatch.

On iOS and visionOS, the approval vault encrypts each enabled account's private key in a separate record bound to its identity, catalog, and publication generation. Each record uses an independent random encryption key protected by Keychain user presence. An approval reads only the selected account's encryption key and decrypts only its record. The vault payload excludes passwords, mnemonics, and stored-wallet JSON. A disclosed encryption key decrypts only its matching record, though the shared Keychain access group and authentication context do not isolate accounts from compromised extension code.

The vault publishes a generation only after every account key is stored. If an account key later disappears, its account is hidden while the other accounts remain available; the app rebuilds the full generation during reconciliation. Metadata checks do not read protected key values or prompt for authentication. Generation changes and changes to the published envelope invalidate existing signing sessions.

Each document loads a native snapshot before exposing accounts, then serves account and chain reads from memory. Explicit connection and signing requests still consult native authority. Cross-tab notifications contain only invalidation hints, and receiving documents fetch their own snapshots. Old browser connection storage is ignored; upgrading requires sites to reconnect but does not remove wallets or custom networks.

Within a supported native profile, incompatible permission data resets to disconnected state so sites can reconnect. Recovery advances permission revisions, invalidates pending approvals for the affected sites, and preserves request identities, completed results, and broadcast recovery records. It requires valid profile identity and transaction records, and a successful durable write.

Disconnect revokes uncommitted requests immediately. Explicitly approved work can finish after its tab closes, and a transaction already committed for broadcast can finish after disconnect. Response retries never restore a revoked grant or repeat its mutation.

The worker retrieves responses through one native poll, with maintenance selected by the worker. Polls without maintenance only observe pending requests; completed responses require fresh authority reconciliation and durable storage synchronization. Acknowledgement remains separate and preserves replay until expiry. Background recovery acknowledges manual account switches and only notifies waiting pages about ordinary request completions.

Removing a wallet or account durably records its revocation before changing the wallet and clears its saved names. Each Safari profile applies outstanding revocations before its next authoritative operation, so an unrelated damaged profile does not block removal. Reimporting or re-enabling the account requires reconnecting. Committed transaction results remain available for recovery until their normal expiry.

Revocation history retains the latest removal of each wallet or account without expiry; repeated removals coalesce. If that history is lost or structurally corrupted, a new history generation invalidates old site permissions as profiles are accessed while preserving request and transaction recovery records. Unreadable storage or a failed durable write still prevents removal.

### iPhone debugger launch stalls in Xcode 27

On Xcode 27.0 (27A266a) with iOS 27.0 (24A437), device debugging can stall at "Configuring Observers for Extensions and XPC Services" with CoreDevice error 1001 for `com.apple.instruments.dtservicehub`. The `Wallet iOS` scheme disables "Debug XPC services used by app" while keeping the app's LLDB debugger enabled.

If launch then stalls at "Launching Big Wallet", Xcode's `IDEDyldMetricsCollector` can also block waiting for the Instruments connection. When the Xcode process sample confirms that wait, quit Xcode and apply this local workaround before reopening it:

```sh
defaults write com.apple.dt.Xcode IDEDyldMetricsEnabled -bool NO
```

This private Xcode preference disables dyld launch-metrics collection across projects; it does not change the app or its release build. Other Instruments-dependent diagnostics may still be unavailable while the device connection reports the capability error. After an Xcode/device-support update, quit Xcode and remove the override to retest the default behavior:

```sh
defaults delete com.apple.dt.Xcode IDEDyldMetricsEnabled
```
