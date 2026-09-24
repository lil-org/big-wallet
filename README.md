# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

* run the xcode project
* recurring manual chores live in [MAINTENANCE.md](MAINTENANCE.md)

### Safari authorization

Native storage owns connected accounts, selected chains, and permission revisions, partitioned by Safari profile and origin. Permission changes and request results commit together. The extension validates Safari's sender metadata before relaying an origin; native messaging supplies the profile. Native storage does not independently attest a webpage's origin.

Each document loads a native snapshot before exposing accounts, then serves account and chain reads from memory. Explicit connection and signing requests still consult native authority. Cross-tab notifications contain only invalidation hints, and receiving documents fetch their own snapshots. Old browser connection storage is ignored; upgrading requires sites to reconnect but does not remove wallets or custom networks.

Within a supported native profile, incompatible permission data resets to disconnected state so sites can reconnect. Recovery advances permission revisions, invalidates pending approvals for the affected sites, and preserves request identities, completed results, and broadcast recovery records. It requires valid profile identity and transaction records, and a successful durable write.

Disconnect revokes uncommitted requests immediately. Explicitly approved work can finish after its tab closes, and a transaction already committed for broadcast can finish after disconnect. Response retries never restore a revoked grant or repeat its mutation.

Removing a wallet or account revokes its site permissions across Safari profiles and clears its saved names. Permission cleanup must succeed before removal; reimporting or re-enabling the account requires reconnecting. Committed transaction results remain available for recovery until their normal expiry.

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
