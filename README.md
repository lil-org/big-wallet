# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

* run the xcode project
* recurring manual chores live in [MAINTENANCE.md](MAINTENANCE.md)

### Safari wire protocol

`Safari Shared/Protocol/wire-protocol.json` defines the shared Swift and JavaScript wire contract. After editing it, run `node Scripts/generate_wire_protocol.mjs --write`, then `Scripts/build_inpage_provider.sh` to rebuild the page provider. Commit the definition and generated files together.

`Scripts/check_wire_protocol.sh` checks that the generated files are current without modifying them. Xcode builds, npm build/test commands, version bumps, and release preflight run this check. The generator uses Node.js built-ins and adds no package dependencies. `BUILD_VERSION` remains release metadata in `bridge_wire.js` and is updated by the existing version-bump script.

### Safari authorization

Native storage owns connected accounts, selected chains, and permission revisions, partitioned by Safari profile and origin. Permission changes and request results commit together. The extension validates Safari's sender metadata before relaying an origin; native messaging supplies the profile. Native storage does not independently attest a webpage's origin.

Claiming a request reserves ownership; it does not authorize privileged work. Accepting the current review produces process-local consent bound to the stored request and authority revisions. The store issues a one-use execution permit for account grants, signing, and new-network additions, and a separate dispatch permit only after a transaction broadcast checkpoint is durable. Stored responses and delivery receipts cannot recreate these capabilities. Ordinary completion is limited to failures, existing connections, address recovery, and known-chain selection.

Each document loads a native snapshot before exposing accounts, then serves account and chain reads from memory. Explicit connection and signing requests still consult native authority. Cross-tab notifications contain only invalidation hints, and receiving documents fetch their own snapshots. Old browser connection storage is ignored; upgrading requires sites to reconnect but does not remove wallets or custom networks.

Within a supported native profile, incompatible permission data resets to disconnected state so sites can reconnect. Recovery advances permission revisions, invalidates pending approvals for the affected sites, and preserves request identities, completed results, and broadcast recovery records. It requires valid profile identity and transaction records, and a successful durable write.

Disconnect revokes uncommitted requests immediately. Explicitly approved work can finish after its tab closes, and a transaction already committed for broadcast can finish after disconnect. Response retries never restore a revoked grant or repeat its mutation.

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
