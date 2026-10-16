# big wallet by [lil.org](https://lil.org)
crypto wallet with a safari extension

ios / macos / visionos

connect like metamask in safari

download on the [app store](https://lil.org/get)

## development

* run the xcode project
* recurring manual chores live in [MAINTENANCE.md](MAINTENANCE.md)

### Swift toolchain and concurrency

Builds and tests run in the dedicated headless macOS VM so app windows,
simulators, and authentication prompts stay off the working host. Start with
`Scripts/test_vm.sh doctor` and `Scripts/test_vm.sh setup`, then run
`Scripts/test_vm.sh run all` or `Scripts/test_vm.sh run extended`. Setup preserves
the existing VirtualBuddy installation. The runner stages immutable source
snapshots and returns logs and test results without opening viewers. See
[VM setup, signing, and test coverage](Scripts/vm/README.md) for the one-time
guest bootstrap and targeted test commands.

The installed guest bootstrap verifies the VM, session, and source snapshot before
loading that snapshot's test harness. Changes to the harness, stage manifest, or
result auditor run with the next snapshot without repeating setup. Changes to the
installed bootstrap, provisioning scripts, or pinned environment require setup
again. Existing development baselines need one setup refresh for this separation.

Use Xcode 27 or newer with Swift 6.4. All native targets use Swift 6 language mode. Minimum supported versions are iOS 26, macOS 15, and visionOS 2.

Default actor isolation is `nonisolated`, with `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` enabled. UI and wallet presentation state belong to `MainActor`; shared storage and service state use actors or `Synchronization.Mutex`. Unannotated async functions stay on their caller's actor, and CPU-intensive work uses `@concurrent`. Values crossing actors must be `Sendable`. Synchronous cancellation, secret invalidation, and lease release use synchronized ownership. File locks continue to coordinate the app, Safari extensions, and approval helper across processes. Never suspend while holding an in-process mutex.

`Scripts/check_swift6.sh` is a host-only alias to the VM runner; guest execution uses its shared stage manifest. Individual stages remain `build`, `test`, `performance`, `tsan`, `fuzz`, and `approval`; the complete VM run also includes Worker and script regression tests. It uses Xcode's default DerivedData inside the guest, runs simulator suites serially, and disables coverage collection. Simulator destinations are resolved from the pinned guest runtimes. Runtime validation on the oldest supported OS versions requires those runtimes or devices separately.

### Safari wire protocol

`Safari Shared/Protocol/wire-protocol.json` defines the shared Swift and JavaScript wire contract. After editing it, run `node Scripts/generate_wire_protocol.mjs --write`, then `Scripts/build_inpage_provider.sh` to rebuild the page provider. Commit the definition and generated files together.

`Scripts/check_wire_protocol.sh` checks that the generated files are current without modifying them. Xcode builds, npm build/test commands, version bumps, and release preflight run this check. The generator uses Node.js built-ins and adds no package dependencies. `BUILD_VERSION` remains release metadata in `bridge_wire.js` and is updated by the existing version-bump script.

Run `Scripts/test_vm.sh run all --stage fuzz` to compare the production JavaScript and Swift codecs inside the VM with independent fixtures, mandatory boundary cases, and seeded mutations. Failures are minimized and saved for replay. Commands and the Unicode-key regression found by the harness are documented in [the protocol README](Safari%20Shared/Protocol/README.md#differential-fuzzing).

### Approval lifecycle and crash tests

```sh
Scripts/check_approval_lifecycle.sh
APPROVAL_CONFIGURATION=Release Scripts/check_approval_lifecycle.sh
Scripts/check_approval_lifecycle.sh --soak --seed 42
Scripts/check_approval_lifecycle.sh --replay /path/to/replay.json
```

The default run checks mandatory scenarios and process-crash boundaries, then runs 32 seeded sequences of 64 actions, alternating native and popup approval. `--soak` defaults to 1,000 sequences of 200 actions; `--seed`, `--sequences`, and `--steps` select a bounded run. Host invocations run in the test VM, which retains failure artifacts in the printed results directory. `Scripts/check_swift6.sh approval` runs the default check.

The standalone `ApprovalCrashWorker` Xcode scheme builds in the default DerivedData without depending on or launching the wallet app or Safari extension. Before building, the runner checks that the target has no application dependencies, wallet entitlements, application entry points, resource-copy phases, or shell-script phases. Its two process roles share only a disposable test directory. Wallet records, metadata, networks, authentication outcomes, and RPC responses are explicit fixtures. Production routing, approval, signing, and durable persistence execute against those dependencies.

The Node parent runs the actual provider, content script, service worker, and popup scripts in separate VM contexts. It controls message delivery and test clocks, records signing and simulated RPC effects outside the native processes, and kills only its own children at acknowledged checkpoints. Restarts retain the same test files and receive new process identities. A failure retains its attempted action prefix, seed, event ledger, browser trace, and storage snapshot; reduction attempts preserve the failing invariant and are capped at 200. Replay executes the scenario again rather than trusting recorded native responses. It preserves recorded scheduling decisions in order and can continue beyond that record after a fix.

Random permanent message drops apply to extension/native transport boundaries. Same-document DOM events can be delayed, duplicated, or reordered; document loss is modeled by navigation or replacement. Arbitrary permanent DOM-event loss is outside the progress guarantee and may leave a provider promise pending before the extension receives it. Replay retains explicit scheduling and fault choices; automatic polling can vary with process scheduling, so its full trace is diagnostic rather than a byte-for-byte replay requirement. A failure that does not reproduce is reported as such.

Fresh user consent may authorize another signing attempt after an ordinary request is abandoned before broadcast commitment. Old consent, polling, delivery retries, and process recovery cannot do so. Once a broadcast checkpoint is committed, recovery preserves its transaction identity without another signing or dispatch, including when the process died before sending. Unexpected exits, missing checkpoints, malformed replies, and watchdog timeouts fail the harness.

Process kills do not simulate power loss; the persistence disk-model tests cover synchronization ordering separately. Browser APIs and authentication are simulated here. Actual Safari suspension, sender metadata, rendering, biometrics, and protected vault keys still require device testing.

### Safari authorization

Ethereum `eth_sign` is unsupported and returns error `4200` without opening an approval. Use `personal_sign` or typed-data signing; there is no raw-signing opt-in or automatic conversion.

Native storage owns connected accounts, selected chains, and permission revisions, partitioned by Safari profile and origin. Permission changes and request results commit together. The extension validates Safari's sender metadata before relaying an origin; native messaging supplies the profile. Native storage does not independently attest a webpage's origin.

Claiming a request reserves ownership; it does not authorize privileged work. Accepting the current review produces process-local consent bound to the stored request and authority revisions. The store issues a one-use execution permit for account grants, signing, and new-network additions, and a separate dispatch permit only after a transaction broadcast checkpoint is durable. Stored responses and delivery receipts cannot recreate these capabilities. Ordinary completion is limited to failures, existing connections, address recovery, and known-chain selection.

A shared execution lifecycle owns the request lock and tracks preparation, authorization, execution, signing use, and broadcast dispatch. Claims capture the stored request binding and authorize directly; there is no intermediate reservation. Copied capabilities share consumption state, and cleanup from an old claim cannot release an approved execution. Consent consumption remains independent so a new claim cannot reuse an earlier acceptance.

Request preparation produces one immutable approval intent from a store-issued request binding. Review and execution use that same payload; execution refreshes account availability, network identity, and authority without rebuilding the approved request. The shared executor owns each acquired claim through authentication, preflight, authorization, completion, and cleanup.

Abandoning an execution releases its local ownership and uses the same recovery rules as a stopped process. Terminal publication receives one attempt; uncertain writes are observed or recovered without repeating privileged work. Interrupted popup approvals require explicit Retry, which builds a fresh review from the current request, account, and network and discards previous nonce and fee edits. Preflight warnings retain their correction controls without retaining execution authority.

Native consent receives one finalization attempt. Subsequent polling only observes the existing execution. Before execution is authorized, unavailable wallet or network data returns the request to explicit Retry on both native and popup approvals. Retry rebuilds the review and requires new consent without extending the request's original deadline. Confirmed account or network changes instead complete the request with the same provider error on both surfaces. Unexpected interruption and durable broadcast recovery retain their existing behavior; observation cannot reuse old consent or repeat dispatch.

The approval surface owns authentication. The transaction engine reserves a frozen review while authentication runs, then performs a fresh fee preflight. Updated fees and recoverable preparation failures appear inline, with Approve, Retry, or Edit Fees as the primary action. Updated fees require another explicit approval and authentication; transaction Retry only refreshes preparation and never signs or extends the request deadline.

Actual task cancellation stops uncommitted work on both native and popup approvals, including authentication, fee preflight, signing, and commit-lease acquisition. Late results are discarded and late leases are released. Retrying abandoned work requires fresh consent; closing a tab or popup does not itself introduce a new task-cancellation signal.

The final cancellation check precedes synchronous durable publication. Once a checkpoint or terminal write starts, its outcome wins: a successful broadcast checkpoint may dispatch once even if cancellation arrives during the write. An uncertain checkpoint never dispatches from that attempt and is resolved through durable observation or recovery. Confirmed checkpoints and completed results survive caller cancellation; recovery cannot repeat signing, restore consumed consent, or send the transaction again.

Each signing session owns one source that binds the account, signing material, freshness checks, and any commit lease. Retiring a vault source's key leaves its captured identity available for result publication; invalidating the source prevents further use. A commit lease arriving after cancellation is released instead of transferred.

The execution lifecycle alone admits and consumes signing attempts; the session
owns key retirement and commit-lease cleanup. Signing produces execution-bound
completions or prepared broadcasts directly. Copies of a prepared broadcast share
its identity and still require the same one-use durable dispatch permit.

On iOS and visionOS, the approval vault encrypts each enabled account's private key in a separate record bound to its identity, catalog, and publication generation. Each record uses an independent random encryption key protected by Keychain user presence. An approval reads only the selected account's encryption key and decrypts only its record. The vault payload excludes passwords, mnemonics, and stored-wallet JSON. A disclosed encryption key decrypts only its matching record, though the shared Keychain access group and authentication context do not isolate accounts from compromised extension code.

The vault publishes a generation only after every account key is stored. If an account key later disappears, its account is hidden while the other accounts remain available; the app rebuilds the full generation during reconciliation. Metadata checks do not read protected key values or prompt for authentication. Generation changes and changes to the published envelope invalidate existing signing sessions.

Each document loads a native snapshot before exposing accounts, then serves account and chain reads from memory. Explicit connection and signing requests still consult native authority. Cross-tab notifications contain only invalidation hints, and receiving documents fetch their own snapshots. Old browser connection storage is ignored; upgrading requires sites to reconnect but does not remove wallets or custom networks.

Within a supported native profile, any corruption in the site-permission map disconnects every site in that Safari profile and resets selected Ethereum chains to mainnet. Sites can then reconnect. Recovery advances permission revisions, invalidates pending approvals that depend on those permissions, and preserves request identities, completed results, broadcast recovery records, and valid disconnect receipts. It requires valid profile identity, revision metadata, and transaction records, and a successful durable write. Wallets, custom-network definitions, and other Safari profiles remain unchanged.

Disconnect revokes uncommitted requests immediately. Explicitly approved work can finish after its tab closes, and a transaction already committed for broadcast can finish after disconnect. Response retries never restore a revoked grant or repeat its mutation.

The worker retrieves responses through one native poll, with maintenance selected by the worker. Polls without maintenance only observe pending requests; completed responses require fresh authority reconciliation and durable storage synchronization. Acknowledgement remains separate and preserves replay until expiry. Background recovery acknowledges manual account switches and only notifies waiting pages about ordinary request completions.

Removing a wallet or account durably records its revocation before changing the wallet and clears its saved names. Each Safari profile applies outstanding revocations before its next authoritative operation, so an unrelated damaged profile does not block removal. Reimporting or re-enabling the account requires reconnecting. Committed transaction results remain available for recovery until their normal expiry.

Revocation history retains the latest removal of each wallet or account without expiry; repeated removals coalesce. If that history is lost or structurally corrupted, a new history generation invalidates old site permissions as profiles are accessed while preserving request and transaction recovery records. Unreadable storage or a failed durable write still prevents removal.

### Password setup and secret exports

New wallet imports accept at most 1 MiB of UTF-8 input. Imported PBKDF2 keystores
must fit a budget of 2,000,000 iterations across all SHA-256 output blocks
(`iterations * ceil(derivedKeyBytes / 32)`). Existing scrypt limits still apply.
These admission limits reject unusually expensive keystores before decryption;
they do not change stored-wallet loading or the app's encryption settings.

Initial password setup only inserts a missing credential; it never replaces an existing password. Unreadable or malformed credentials, and wallet records without their password, stop setup and offer Retry. Competing setup sessions must authenticate with the credential that was actually stored.

During macOS startup or onboarding, a credential-storage failure cancels the current step, clears password drafts, and shows Retry in the same window. Only explicit Retry restarts the flow from current storage state; an existing password requires fresh authentication. Closing the flow cancels its pending wallet-open and pre-authentication approval requests.

On macOS, password prompts for wallet actions and approvals use a sheet attached to the requesting window. Each window authenticates independently. Closing that window or retiring its approval cancels the prompt; an authentication result is never shared with another action.

Seed phrases and private keys disappear when their scene or window becomes inactive or closes. Returning requires a fresh reveal and authentication. Secret clipboard copies stay on the current device and expire after 30 seconds. iOS and visionOS enforce expiration through the system; macOS uses elapsed time while the app is running, checks ownership before clearing, and clears its own copy on normal termination. Forced termination can prevent macOS cleanup. These controls do not guarantee erasure of Swift string storage or copies already obtained by another application.

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
