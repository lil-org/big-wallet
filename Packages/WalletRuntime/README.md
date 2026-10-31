# Wallet runtime

The application, native approval helper, and Safari extensions compose four
libraries. This is an API boundary enforced by Swift modules; all code still runs
inside the existing processes and uses the existing entitlements.

| Module | Source ownership | Dependencies |
| --- | --- | --- |
| `WalletDomain` | Immutable wallet/account values, requests, wire codec, transaction and fee values, endpoint identities, nonsecret encoders, service contracts | Foundation and pure system utilities |
| `WalletAuthority` | Wallet storage and credentials, vault, request storage and revocation, bound reviews, authentication/consent, signing and durable execution | Domain, private storage support, private C crypto |
| `WalletFlows` | Browser/native dispatch, popup presentation, native observation/retry, helper launch orchestration and application composition | Domain and Authority |
| `WalletNetworking` | Ethereum and Solana RPC, request admission and streaming, preparation, fees, broadcast and confirmation, Alchemy credentials | Domain, private storage support |

`WalletStorageSupport` holds the shared file-lock implementation. It has no library
product. `CWalletCrypto` is reachable only through Authority. Authority and
Networking cannot import one another. Flows cannot import Networking, private storage support, Security, LocalAuthentication or private crypto. `ApplicationServices` composes the public
libraries through `WalletAuthoritySystem` in Flows and `AuthorityRuntime` in Authority and injects localized messages, transaction preparation, and signed
transaction broadcasting. App-owned extensions format values for UI.

## Concurrency

Default actor isolation is `nonisolated`, with `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` enabled. UI and wallet presentation state belong to `MainActor`; shared storage and service state use actors or `Synchronization.Mutex`. Unannotated async functions stay on their caller's actor, and CPU-intensive work uses `@concurrent`. Values crossing actors must be `Sendable`. Synchronous cancellation, secret invalidation, and lease release use synchronized ownership. File locks continue to coordinate the app, Safari extensions, and approval helper across processes. Never suspend while holding an in-process mutex.

## Approval and secret access

Authority owns the request from admission through durable completion. UI adapters
receive review values and opaque reference handles. Authentication challenges are
bound to the authority instance and a specific purpose. Only credential
verification can issue a grant. Copies share consumption and invalidation state;
review changes, cancellation, expiry, and credential changes invalidate the
corresponding authority. Access/export challenges and initial-backup authorization
expire after 150 continuous-clock seconds, including device sleep. Backup grant
issuance preserves its original deadline. Native reviews capture one continuous
admission horizon and also retain their absolute request deadline; replacement
challenges cannot renew that horizon. Persisted request and recovery timestamps
remain wall-clock based.

A wallet access session permits loading and reviewing wallet metadata. Signing
requires a grant bound to the current message or transaction review. Secret
export requires its own source-bound challenge and grant. Initial backup uses a
short-lived, one-use authorization issued when a wallet is created. Ordinary
review, preparation, and signing results contain no mnemonic or private key.

Ethereum typed data is validated off the main actor before signing authentication.
Catalog resolution reuses the prepared content rather than parsing it again.
After asynchronous preparation, approval presentation rechecks the current
request and wallet state before publishing a review. A prepared value
retains the original JSON and its digest through review, consent, and execution;
signing does not parse or hash typed data while holding the authority store lock.
Construction accepts only validated JSON, never a caller-supplied digest.

Typed-data preparation permits at most 256 KiB of UTF-8 input, 64 JSON nesting
levels, 65,536 JSON tokens, 256 types, 128 fields per type, and 4,096 declared
fields. Dependency, value, and array-type nesting is limited to 32, with 4,096
elements per array. Repeated traversal and encoding share budgets of 65,536 work
steps and 8 MiB of processed bytes. Invalid or over-budget data follows the normal
request failure path without opening a signing prompt. Existing supported values
within the limits retain their signing semantics.

Transaction edits are applied to the existing review. Authority validates
preflight output against that review before accepting it. A fee change requiring
new consent returns to review; preparation cannot replace immutable signing
fields.

### Execution and recovery

Claiming a request reserves ownership; it does not authorize privileged work. Accepting the current review produces process-local consent bound to the stored request and authority revisions. The store issues a one-use execution permit for account grants, signing, and new-network additions, and a separate dispatch permit only after a transaction broadcast checkpoint is durable. Stored responses and delivery receipts cannot recreate these capabilities. Ordinary completion is limited to failures, existing connections, address recovery, and known-chain selection.

A shared execution lifecycle owns the request lock and tracks preparation, authorization, execution, signing use, and broadcast dispatch. Claims capture the stored request binding and authorize directly; there is no intermediate reservation. Copied capabilities share consumption state, and cleanup from an old claim cannot release an approved execution. Consent consumption remains independent so a new claim cannot reuse an earlier acceptance.

Request preparation produces one immutable approval intent from a store-issued request binding. Review and execution use that same payload; execution refreshes account availability, network identity, and authority without rebuilding the approved request. The shared executor owns each acquired claim through authentication, preflight, authorization, completion, and cleanup.

Abandoning an execution releases its local ownership and uses the same recovery rules as a stopped process. Terminal publication receives one attempt; uncertain writes are observed or recovered without repeating privileged work. Interrupted popup approvals require explicit Retry, which builds a fresh review from the current request, account, and network and discards previous nonce and fee edits. Preflight warnings retain their correction controls without retaining execution authority.

Canceling popup authentication returns directly to review after the claim is released and current authority is verified. When the request, account catalog, and network are unchanged, the review keeps its nonce and fee edits, estimates, and notices. The review receives a new token; another Approve requires a new claim, fresh authentication, and fresh consent. Changed authority rebuilds the review or resolves the request through its normal checks. Task cancellation, expired deadlines, unavailable authority, and uncertain claim release retain their interruption or recovery behavior.

Native consent receives one finalization attempt. Subsequent polling only observes the existing execution. Before execution is authorized, unavailable wallet or network data returns the request to explicit Retry on both native and popup approvals. Retry rebuilds the review and requires new consent without extending the request's original deadline. Confirmed account or network changes instead complete the request with the same provider error on both surfaces. Unexpected interruption and durable broadcast recovery retain their existing behavior; observation cannot reuse old consent or repeat dispatch.

The approval surface owns authentication. The transaction engine reserves a frozen review while authentication runs, then performs a fresh fee preflight. Updated fees and recoverable preparation failures appear inline, with Approve, Retry, or Edit Fees as the primary action. Updated fees require another explicit approval and authentication; transaction Retry only refreshes preparation and never signs or extends the request deadline.

Actual task cancellation stops uncommitted work on both native and popup approvals, including authentication, fee preflight, signing, and commit-lease acquisition. Late results are discarded and late leases are released. Retrying abandoned work requires fresh consent; closing a tab or popup does not itself introduce a new task-cancellation signal.

The final cancellation check precedes synchronous durable publication. Once a checkpoint or terminal write starts, its outcome wins: a successful broadcast checkpoint may dispatch once even if cancellation arrives during the write. An uncertain checkpoint never dispatches from that attempt and is resolved through durable observation or recovery. Confirmed checkpoints and completed results survive caller cancellation; recovery cannot repeat signing, restore consumed consent, or send the transaction again.

Unlocking produces a request-scoped signing preparation that cannot sign or acquire a commit lease. After authorization, the executor consumes that preparation once to create a session bound to the approved operation. Failed consumption retires the source; validation failures do not consume the permit's signing slot. After transfer, the session owns the source, and invalidating the old preparation has no effect on it. Retiring a vault source's key leaves its captured identity available for result publication; invalidating the source prevents further use. A commit lease arriving after cancellation is released instead of transferred.

The execution lifecycle alone admits and consumes signing attempts; the session
owns key retirement and commit-lease cleanup. Signing produces execution-bound
completions or prepared broadcasts directly. Copies of a prepared broadcast share
its identity and still require the same one-use durable dispatch permit.

Fresh user consent may authorize another signing attempt after an ordinary request is abandoned before broadcast commitment. Old consent, polling, delivery retries, and process recovery cannot do so. Once a broadcast checkpoint is committed, recovery preserves its transaction identity without another signing or dispatch, including when the process died before sending.

### Mobile approval vault

On iOS and visionOS, the approval vault encrypts each enabled account's private key in a separate record bound to its identity, catalog, and publication generation. Each record uses an independent random encryption key protected by Keychain user presence. An approval reads only the selected account's encryption key and decrypts only its record. The vault payload excludes passwords, mnemonics, and stored-wallet JSON. A disclosed encryption key decrypts only its matching record, though the shared Keychain access group and authentication context do not isolate accounts from compromised extension code.

The vault publishes a generation only after every account key is stored. If an account key later disappears, its account is hidden while the other accounts remain available; the app rebuilds the full generation during reconciliation. Metadata checks do not read protected key values or prompt for authentication. Generation changes and changes to the published envelope invalidate existing signing sessions.

Safari vault envelopes and empty invalidation markers use the same durable replacement
helper as request storage: full file synchronization, atomic replacement, directory
synchronization, and a final file barrier. Publication succeeds only after those
barriers and readback verification. Catalog, unlock, and signing-current reads
also synchronize the exact open envelope file and its directory before accepting
the snapshot, rejecting replacement or modification during synchronization.
Failed publication remains failed; a later successful reader barrier can establish
durability independently. Admission, popup, and signing validation perform these
durable reads off the main actor and recheck cancellation and current ownership
after awaiting them. Host publication metadata remains advisory.

## Site permissions and revocation

Native storage owns connected accounts, selected chains, and permission revisions, partitioned by Safari profile and origin. Permission changes and request results commit together.

Within a supported native profile, any corruption in the site-permission map disconnects every site in that Safari profile and resets selected Ethereum chains to mainnet. Sites can then reconnect. Recovery advances permission revisions, invalidates pending approvals that depend on those permissions, and preserves request identities, completed results, broadcast recovery records, and valid disconnect receipts. It requires valid profile identity, revision metadata, and transaction records, and a successful durable write. Wallets, custom-network definitions, and other Safari profiles remain unchanged.

Disconnect revokes uncommitted requests immediately. Explicitly approved work can finish after its tab closes, and a transaction already committed for broadcast can finish after disconnect. Response retries never restore a revoked grant or repeat its mutation.

Removing a wallet or account durably records its revocation before changing the wallet and clears its saved names. Each Safari profile applies outstanding revocations before its next authoritative operation, so an unrelated damaged profile does not block removal. Reimporting or re-enabling the account requires reconnecting. Committed transaction results remain available for recovery until their normal expiry.

Revocation history coalesces repeated removals and is bounded to 8 MiB and 65,536 combined wallet/account entries. If a new removal would exceed either limit, a new history generation records the complete current removal batch and disconnects existing sites as their profiles are next accessed. Sites must reconnect; dependent approvals are invalidated, while selected chains, completed responses, and committed transaction recovery records remain available. A batch too large for an empty history is rejected before changing the wallet or approval vault. Publication precedes the wallet mutation; a later mutation failure does not restore old permissions.

Lost or structurally corrupted history retains its existing generation-reset recovery. Already oversized history, unsafe files, and unreadable storage prevent removal without replacing the stored history. Failed durable publication also prevents removal, but a replacement may already be visible if rename succeeded before synchronization failed; the replacement is not rolled back.

Shared profile, revocation, and approval-vault reads use bounded regular-file snapshots: size checks and reads use the same descriptor, reject changes during the read, and never follow symlinks below the trusted container boundary. Durable writes and lock acquisition use the same anchored directory traversal. Locks validate that the acquired descriptor still names the requested file; this does not protect against arbitrary interference by another process with write access after acquisition.

The [Safari protocol guide](../../Safari%20Shared/Protocol/README.md#caller-context) describes caller-context trust, document snapshots, and response delivery.

## Secret ownership and management access

`SecretBytes` owns private allocations inside Authority. Its synchronous borrows do
not hold the lifetime mutex during cryptographic work. Invalidation refuses new
borrows immediately; the final active borrow wipes and releases the allocation.
Passwords, seeds, private keys, vault keys and sensitive intermediate buffers use
this owner. Framework-managed strings, Keychain results and CryptoKit internals
can still contain copies outside this allocation's control.

Password decoding preserves released BOM and Unicode equality semantics, stored
bytes, and KDF inputs. Authorized exports return
an opaque `WalletExportedSecret`; presentation owns its lifetime and creates text
only for display or clipboard operations.

Wallet creation, import, account changes, deletion and preview require a current
`WalletAccessSession` inside Authority, including validation at the source commit
boundary. Preview lifetime binds to access and encrypted secret identity while
allowing names and enabled-account metadata to refresh. Initial password setup
remains an atomic preauthentication operation.

### Account editing

The account editor merges external account changes into its open draft. Local additions and removals are reapplied to the latest wallet; untouched accounts follow that wallet's current state. An edit already satisfied externally becomes clean, so later external changes apply normally. Existing preview pages remain available, and only removal or replacement of the wallet closes the editor. Saving still merges against current storage and cannot remove the final account.

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

## Network handoff

Domain defines `TransactionPreparing`, `SignedTransactionBroadcasting`,
`BroadcastRequest`, and `BroadcastResult`. The executor signs internally, persists
the transaction identity and broadcast checkpoint, consumes the dispatch permit,
and then releases signed bytes to the injected broadcaster. The broadcaster never
receives consent, a signing source, or a dispatch permit.

Results distinguish acceptance, rejection, definite non-submission, uncertain
submission, and confirmation failure. Recovery uses the durable transaction
identity without signing or submitting again. Ethereum submits once. Solana may
retry identical signed bytes once after an HTTP 401 with a valid RPC error reply.
Native RPC replies must carry version 2.0, the matching numeric request ID, and
exactly one valid result or error. Malformed submission replies remain uncertain
and cannot authorize another submission. Public RPC admission and
response budgets are independent of approval execution. Networking retains only
its separate RPC-auth Keychain credentials.

Native Ethereum and Solana RPC reject redirects and limit each response to 16 MiB,
64 JSON nesting levels, and 65,536 JSON tokens. Byte limits apply while streaming
and after UTF-8 normalization. A limit violation discards the response and stops
the operation without retry or authorization replacement; an observed HTTP 401
still invalidates its credential. Submission remains uncertain, and a Solana
confirmation failure retains the already accepted signature.

Optional metadata uses the same bounded streaming transport. Price responses are
limited to 64 KiB and 10 seconds total, with 16 JSON nesting levels and 4,096
tokens; the byte limit also applies after UTF-8 normalization. Function-signature
responses are limited to 16 KiB and 5 seconds total, with 32 levels of tuple/array
nesting and 1,024 type nodes before caching or decoding. Both reject redirects and
discard partial responses on failure. Deadlines do not restart when data arrives
or another subscriber joins. Failed price refreshes retain the previous prices;
failed signature lookups are not cached. One signature subscriber's cancellation
does not stop other subscribers, but the last cancellation stops the request.

ABI interpretation also limits decoded expansion. Each call shares budgets of
16,384 decoded values, 65,536 work steps, 1 MiB of decoded string data, and 1 MiB
of JSON output. Fixed and dynamic arrays consume the same budget, including
zero-size tuples and repeated offsets. Schema parsing is limited to 1,024 nodes
and 32 nesting levels, with at most 256 KiB of ABI JSON and 1 MiB of calldata.
Decoding and serialization check cancellation. Exceeding a limit discards the
interpretation; transaction presentation retains its raw-data fallback.

Compatibility is required for released-main wallet storage and external protocol
standards. Intermediate development formats do not require fallback readers or
migrations.

## HTTP sessions

Production clients use `URLSession` directly. `WalletHTTPSession.make()` creates
ephemeral sessions with cookies, shared credential storage and response caching
disabled. Clients retain their existing redirect delegates, streaming limits,
cancellation and application retry policies. Foundation handles TLS and HTTP
authentication. These settings do not promise a single wire request or
operation-scoped Basic/Digest authentication.

## Validation ownership

Package XCTest targets own internal runtime tests on macOS, iOS, and visionOS.
Application test targets retain UI and composition coverage. `Tests/Support`
contains fixture utilities and resources; no production target depends on it.
The macOS crash worker is a separate `../WalletRuntimeHarness` package, with
explicit validation-only testability. Safari VM composition uses app-owned
fixture adapters behind `BW_SAFARI_VM_TESTING`; runtime source has no fixture
conditional or implicit fixture singleton.

`Scripts/check_runtime_boundaries.mjs` checks dependencies, source ownership,
private APIs, test-only imports, and Xcode compilation membership. Its compiler
fixtures use ordinary imports: positive fixtures must compile and negative
fixtures must fail for the expected access-control reason. The committed VM test
inventory rejects missing, duplicate, skipped, unexpected, and zero-test results.

Run native validation only through `Scripts/test_vm.sh`; see
[`Scripts/vm/README.md`](../../Scripts/vm/README.md). Focused package compilation is
available through `--stage runtime`; executing XCTest requires `--stage test`.
The complete acceptance run includes builds, tests, thread and address sanitizers, lifecycle
exploration, wire fuzzing, and Safari integration in the VM.

## Deterministic race coverage

Small module fixtures enumerate every legal merge of two actors with at most
three steps each, up to 20 schedules. They exercise the production authentication,
signing, preparation, and RPC gates. The lifecycle worker extends the existing
production harness with tracked operations, cancellation, acknowledged gates,
and processed-event fences. Synchronous publication and mutex regions remain
synchronous.

Cross-process exploration, captured source and binary identities, replay, and
minimization are documented in the [VM lifecycle guide](../../Scripts/vm/README.md#approval-lifecycle-and-crash-tests).
These bounds establish reproducible coverage of the declared dependency races.
They do not enumerate every possible Swift executor ordering or provide
process-level containment.

API boundary fixtures compile twice: as an external consumer and as a distinct
module using the production package identity. Both must reject raw secrets,
capability construction and management calls without access. Existing core test
fixtures remain test-only; Flow tests use ordinary Authority imports.
