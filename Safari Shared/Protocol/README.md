# Safari wire protocol

`wire-protocol.json` defines the messages owned by Big Wallet, their shared constants, and browser routing subjects. The dependency-free Node generator emits the browser codec in `Resources/protocol.generated.js` and the native codec in `Packages/WalletRuntime/Sources/WalletDomain/WireProtocol.generated.swift`.

From the repository root:

```sh
node Scripts/generate_wire_protocol.mjs --write
Scripts/build_inpage_provider.sh
node Scripts/generate_wire_protocol.mjs --check
```

Edit the definition, regenerate both codecs, and rebuild the inpage provider. Commit the definition and generated files together. `--write` updates only changed files; `--check` checks without writing. `--root` selects an output repository root and `--definition` selects an alternative definition, for isolated generation tests.

`Scripts/check_wire_protocol.sh` checks that the generated files are current without modifying them. Xcode builds, npm build/test commands, version bumps, and release preflight run this check. The generator uses Node.js built-ins and adds no package dependencies. `BUILD_VERSION` remains release metadata in `bridge_wire.js` and is updated by the existing version-bump script.

The definition uses references, scalar constant references, exact object fields, dictionaries, arrays, unions, enums, and constrained primitives. An optional field may be absent; it accepts null only when its rule explicitly includes null. String lengths use UTF-16 code units in both generated codecs. Unknown vocabulary, invalid references, recursive definitions, and generated-name collisions fail before outputs are written.

Known field names and string constants compare exactly. Objects containing distinct keys that are canonically equivalent Unicode strings are rejected before snapshotting; a single non-NFC key is preserved without normalization. This prevents Swift dictionary conversion from silently merging content that JavaScript keeps distinct.

`MAX_JSON_DEPTH` limits nesting to 64 object/array containers, including the message envelope, in both codecs. `depthReservations` gives terminal responses a 63-container budget so their delivery wrappers fit within that limit. Native snapshots retain Foundation decimal values without converting them to binary floating point.

JavaScript exposes `BigWalletProtocol.constants`, `decode(name, value)`, `isValid(name, value)`, and `build(name, value)`. Decoding returns a fresh, deeply frozen snapshot with null-prototype objects. It reads own data properties, rejects accessors and cycles, and does not call payload serializers. `decode` returns null on invalid input, so use `isValid` for a contract that itself permits null. `build` throws for invalid input.

Swift exposes `WireProtocol.Message`, `validate(_:value:)`, and `decode(_:value:)`. `object(_:value:)` produces a detached `ValidatedObject` containing its contract and `json` dictionary. The raw `Data` overloads `decode(_:from:)` and `object(_:from:)` check the original Foundation object tree before bridging dictionaries. Application models map these values to their domain types; consumers accepting a validated object check its contract. Safari ingress snapshots the original message before dictionary conversion and maps internal commands directly from validated objects. The generic `Decoder` overload supports already-decoded domain/storage values; it cannot recover keys already merged by a decoder, so raw untrusted JSON must use the `Data` or original-Foundation-value entry points.

## Caller context

The codecs check structure. Browser ingress constructs one immutable transport context from extension sender metadata before asynchronous work. Content-to-worker requests do not supply host, origin, or privacy assertions. Native messages carry a flat `__bwContext` with a source (`site`, `popup`, or `worker`), explicit privacy, and site/document metadata for site requests. The flat metadata does not add nesting around the existing domain payload. Optional browser `documentId` remains informational; provider generations still control delivery and permissions remain origin-scoped. Native ingress snapshots the original Foundation tree, extracts and validates context once, and adds the OS-provided Safari profile identifier. Source/command restrictions and site/payload consistency are checked before dispatch; native authority revisions, response correlation, ownership, deadlines, account selection, and transaction validity retain their existing checks. Unknown or malformed privacy metadata blocks wallet operations without lookup fallbacks; explicit private evidence takes precedence. The authenticated popup may assert its browser-derived privacy in popup-only runtime messages. Popup-selected tabs and retained requests are operation targets, not caller identities, and worker recovery does not depend on an active tab. Native code trusts these validated extension assertions about sites; the context is not independent OS attestation of webpage origins and does not protect against a compromised extension.

External RPC data, transaction parameters, and typed-data contents retain their own validators. Native-only approval mutations, approved account descriptors, profile identities, and execution permits are not wire fields.

## Provider objects

Inpage providers support ordinary SDK objects, inherited getters and serializers, listener reentry, and request snapshots that remain stable after caller mutation. Admission snapshots preserve native JSON semantics and call caller serializers only during normalization. Detached snapshots shadow inherited `toJSON` methods so later changes to prototype `toJSON` methods cannot rewrite already-normalized payloads.

Solana object APIs support ordinary web3.js-compatible legacy and versioned transactions, including versioned transactions containing legacy messages and the SDK's built-in getters. Signing captures the message bytes and resulting signature array before waiting for approval, compares each current message once when a response arrives, and validates the complete batch before applying any returned wallet signature. A changed message, replaced signature array, invalid signature, unavailable signer, read-only signature slot, or overlapping batch output rejects the operation. Successful calls return the original transaction objects and preserve their captured signature arrays and unrelated cosignatures. Custom Proxies, reentrant serializers, and signature getters or setters are outside this contract; descriptor reconstruction and recovery from side effects during signature writes are not guaranteed. Native authorization and committed-result handling remain authoritative.

Wire boundaries reject malformed data, accessors, cycles, and failing proxy traps before passing detached records to internal handlers. Private runtime collections and generated payload containers use ordinary JavaScript operations. Arbitrary replacement of global constructors, collection methods, array-index accessors, or reflection functions is outside the supported behavior; the provider does not guarantee recovery from that interference. Inexpensive captured JSON and reflection functions, null-prototype data records, and the snapshot `toJSON` protection remain useful safeguards, not a security boundary within the page's JavaScript realm. Native authorization, origin checks, and approval validation remain authoritative.

Internal transport currentness checks only read installation state; they do not invoke callbacks, mutate provider state, or throw. Transport replies arrive asynchronously through the browser message bridge. Tests for these internal hooks preserve that contract; reentry coverage belongs at caller-controlled inputs and public event listeners.

## RPC forwarding

Ethereum `eth_sign` is unsupported and returns error `4200` without opening an approval. Use `personal_sign` or typed-data signing; there is no raw-signing opt-in or automatic conversion.

Public Ethereum RPC forwarding validates and reconstructs each request in native code. Unknown vendor methods, simulations, traces, raw transaction broadcasts, and user operations remain available. The forwarding path rejects wallet-owned methods and known node administration, account management, development-node control, and debug mutation/file operations. Normal provider methods still use their existing local or approval paths, and public batches are split into individual calls. Forwarding permission does not grant retry permission: unknown methods and submissions are never automatically replayed.

RPC forwarding has separate capacity from approvals and transaction execution. Limits are 4 MiB per request, 16 MiB per response, 65,536 JSON tokens (values and object keys) per request or response checked before parsing, four active calls per Safari profile/origin and eight per native extension process, and 64/128 outstanding calls respectively. The 16 MiB retained-request budget counts input bodies plus canonical output capacity reserved before allocation; buffered response bodies are capped at 32 MiB per process. Queued requests wait at most 30 seconds; the full native operation has a 170-second monotonic deadline, including authorization recovery. Responses stream under the byte budget. Cancellation stops network work, and timed-out work keeps its slot until it actually exits. Limits return `-32005`; transport/deadline failures return `-32603`, with `error.data.reason` and `error.data.dispatched`. A failure after dispatch does not establish that a submission was rejected by the endpoint.

## Account snapshots and response delivery

Each document loads a native snapshot before exposing accounts, then serves account and chain reads from memory. Explicit connection and signing requests still consult native authority. Cross-tab notifications contain only invalidation hints, and receiving documents fetch their own snapshots. Old browser connection storage is ignored; upgrading requires sites to reconnect but does not remove wallets or custom networks.

The worker retrieves responses through one native poll, with maintenance selected by the worker. Polls without maintenance only observe pending requests; completed responses require fresh authority reconciliation and durable storage synchronization. Acknowledgement remains separate and preserves replay until expiry. Background recovery acknowledges manual account switches and only notifies waiting pages about ordinary request completions.

Native authority owns permission changes, revocation, approval, and durable completion;
see the [runtime guide](../../Packages/WalletRuntime/README.md#site-permissions-and-revocation).

## Differential fuzzing

Run `Scripts/test_vm.sh run all --stage fuzz` from the host, or use `run extended
--stage fuzz` for the three fixed 20,000-case seeds. The VM retains the logs and
failure artifacts. The following low-level commands run from the repository
root inside the guest with Node.js and the project's Xcode Swift toolchain:

```sh
node Scripts/fuzz_wire_protocol.mjs
node Scripts/fuzz_wire_protocol.mjs --seed 42 --iterations 20000
node Scripts/fuzz_wire_protocol.mjs --iterations 0
node Scripts/fuzz_wire_protocol.mjs --replay /path/to/failure.json
```

Inside the guest, `npm run test:protocol-fuzz` in
`Safari Shared/Inpage Provider` runs the same
bounded check. The VM's `all` profile includes it. Ordinary `npm test` runs the
corpus and harness tests without requiring Swift.

The runner compiles the actual generated Swift codec with `Scripts/ProtocolFuzzOracle.swift` into a temporary standalone executable. It does not build or launch the wallet, access wallet data, or change DerivedData. Both codecs receive the same serialized candidate. It compares acceptance and decoded snapshots across native value and raw-data entry points, and checks JavaScript `decode`, `build`, and snapshot revalidation. Contract inventories and independently labeled positive/negative fixtures prevent an all-reject or all-accept implementation from appearing correct.

Snapshot comparisons treat signed zero consistently across serializers while retaining other numeric differences. Parser differences are diagnostic when both codecs reject; they do not cause a failure on their own.

Every run includes all independent contract fixtures and boundary mutations, followed by 5,000 random cases by default. `--iterations` controls only the random cases and is capped at 100,000 to bound corpus memory; zero retains the fixtures and boundaries. The unsigned 32-bit `--seed` defaults to `12648430`. Mutations cover missing/null/extra fields, prototype-named keys, numeric limits, token formats, UTF-16 string lengths, array limits, and nested container budgets. Random cases combine schema-generated values with mutations of valid fixtures. Generated candidates use finite JSON numbers and well-formed Unicode; replay accepts verbatim JSON text for additional parser cases. This tests codec behavior, not browser sender authorization or approval state transitions.

On the first discrepancy the command exits nonzero, attempts up to 200 reductions preserving the discrepancy, and writes an artifact containing the original input, reduced input, seed, and both outcomes. It rechecks the reduction, falls back to the original case if reduction fails or no longer reproduces, and records whether the discrepancy reproduced. `--no-minimize` disables reduction. Artifacts default to a printed temporary directory; use `--failure-dir /path/to/artifacts` to retain them for CI. Saved artifacts and arrays of `{ "type": "RPCResponse", "json": "...", "expectedValid": true }` can be replayed without regenerating the corpus. Oracle crashes, invalid replies, and timeouts fail the run rather than count as rejected inputs. `--timeout-ms` bounds each oracle exchange and shutdown (default 10 seconds).

### Unicode-key regression

The initial default-seed run exposed distinct keys such as `é` and `e\u0301` being preserved by JavaScript but merged by Swift dictionary conversion. Both validators accepted the original input, so acceptance-only testing missed the content change. Both codecs now reject these ambiguous objects; ordinary non-NFC keys remain supported. The captured, minimized Solana request is retained as an expected-rejection regression and replayed in every generated run. Shared fixtures also cover NFC/NFD, Hangul, and Kelvin-sign collisions and exact field names.

Replay the retained Unicode-key, numeric comparison, and deep-input regressions:

```sh
node Scripts/fuzz_wire_protocol.mjs --replay 'Safari Shared/Tests/fixtures/protocol_fuzz_regressions.json'
```
