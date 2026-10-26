# Wallet runtime

The application, native approval helper, and Safari extensions compose three
libraries. This is an API boundary enforced by Swift modules; all code still runs
inside the existing processes and uses the existing entitlements.

| Module | Source ownership | Dependencies |
| --- | --- | --- |
| `WalletDomain` | Immutable wallet/account values, requests, wire codec, transaction and fee values, endpoint identities, nonsecret encoders, service contracts | Foundation and pure system utilities |
| `WalletAuthority` | Wallet storage and credentials, vault, request storage and revocation, review state machines, authentication/consent, signing, durable execution | Domain, private storage support, private C crypto |
| `WalletNetworking` | Ethereum and Solana RPC, request admission and streaming, preparation, fees, broadcast and confirmation, Alchemy credentials | Domain, private storage support |

`WalletStorageSupport` holds the shared file-lock implementation. It has no library
product. `CWalletCrypto` is reachable only through Authority. Authority and
Networking cannot import one another. `ApplicationServices` composes the public
libraries and injects localized messages, transaction preparation, and signed
transaction broadcasting. App-owned extensions format values for UI.

## Approval and secret access

Authority owns the request from admission through durable completion. UI adapters
receive review values and opaque reference handles. Authentication challenges are
bound to the authority instance and a specific purpose. Only credential
verification can issue a grant. Copies share consumption and invalidation state;
review changes, cancellation, expiry, and credential changes invalidate the
corresponding authority.

A wallet access session permits loading and reviewing wallet metadata. Signing
requires a grant bound to the current message or transaction review. Secret
export requires its own source-bound challenge and grant. Initial backup uses a
short-lived, one-use authorization issued when a wallet is created. Ordinary
review, preparation, and signing results contain no mnemonic or private key.

Transaction edits are applied to the existing review. Authority validates
preflight output against that review before accepting it. A fee change requiring
new consent returns to review; preparation cannot replace immutable signing
fields.

## Network handoff

Domain defines `TransactionPreparing`, `SignedTransactionBroadcasting`,
`BroadcastRequest`, and `BroadcastResult`. The executor signs internally, persists
the transaction identity and broadcast checkpoint, consumes the dispatch permit,
and then releases signed bytes to the injected broadcaster. The broadcaster never
receives consent, a signing source, or a dispatch permit.

Results distinguish acceptance, rejection, definite non-submission, uncertain
submission, and confirmation failure. Recovery uses the durable transaction
identity without signing or submitting again. Ethereum submits once. Solana may
retry identical signed bytes once after an HTTP 401. Public RPC admission and
response budgets are independent of approval execution. Networking retains only
its separate RPC-auth Keychain credentials.

Wallet, wire, and durable-storage formats retain the existing representation.
This refactor does not add readers or migrations for intermediate branch versions.

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
The complete acceptance run includes builds, tests, thread sanitizer, lifecycle
exploration, wire fuzzing, and Safari integration in the VM.

## Deterministic race coverage

Small module fixtures enumerate every legal merge of two actors with at most
three steps each, up to 20 schedules. They exercise the production authentication,
signing, preparation, and RPC gates. The lifecycle worker extends the existing
production harness with tracked operations, cancellation, acknowledged gates,
and processed-event fences. Synchronous publication and mutex regions remain
synchronous.

Cross-process exploration rebuilds disposable fixtures and explores deterministic
prefixes. The `all` profile bounds exploration to two requests, one fault/restart,
preemption bound 1, 64 transitions, and 256 traces per configuration. `extended`
uses three requests, two faults/restarts, preemption bound 2, 128 transitions, and
4,096 traces. Exhausted required frontiers fail as incomplete. Failure artifacts
record the captured source snapshot and worker binary hashes,
the original witness, durable observations, and external effects. Replay checks
the exact enabled and selected actions, rejecting omitted or additional choices.
Minimization retains scheduling decisions and requires two identical reproductions
before accepting a reduced witness; replay against newer source records that
source separately without replacing the original identity.

These bounds establish reproducible coverage of the declared dependency races.
They do not enumerate every possible Swift executor ordering or provide
process-level containment.
