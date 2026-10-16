# Safari wire protocol

`wire-protocol.json` defines the messages owned by Big Wallet, their shared constants, and browser routing subjects. The dependency-free Node generator emits the browser codec in `Resources/protocol.generated.js` and the native codec in `WireProtocol.generated.swift`.

From the repository root:

```sh
node Scripts/generate_wire_protocol.mjs --write
node Scripts/generate_wire_protocol.mjs --check
```

Edit the definition and regenerate both outputs together. `--write` updates only changed files; `--check` checks without writing. `--root` selects an output repository root and `--definition` selects an alternative definition, for isolated generation tests.

The definition uses references, scalar constant references, exact object fields, dictionaries, arrays, unions, enums, and constrained primitives. An optional field may be absent; it accepts null only when its rule explicitly includes null. String lengths use UTF-16 code units in both generated codecs. Unknown vocabulary, invalid references, recursive definitions, and generated-name collisions fail before outputs are written.

Known field names and string constants compare exactly. Objects containing distinct keys that are canonically equivalent Unicode strings are rejected before snapshotting; a single non-NFC key is preserved without normalization. This prevents Swift dictionary conversion from silently merging content that JavaScript keeps distinct.

`MAX_JSON_DEPTH` limits nesting to 64 object/array containers, including the message envelope, in both codecs. `depthReservations` gives terminal responses a 63-container budget so their delivery wrappers fit within that limit. Native snapshots retain Foundation decimal values without converting them to binary floating point.

JavaScript exposes `BigWalletProtocol.constants`, `decode(name, value)`, `isValid(name, value)`, and `build(name, value)`. Decoding returns a fresh, deeply frozen snapshot with null-prototype objects. It reads own data properties, rejects accessors and cycles, and does not call payload serializers. `decode` returns null on invalid input, so use `isValid` for a contract that itself permits null. `build` throws for invalid input.

Swift exposes `WireProtocol.Message`, `validate(_:value:)`, and `decode(_:value:)`. `object(_:value:)` produces a detached `ValidatedObject` containing its contract and `json` dictionary. The raw `Data` overloads `decode(_:from:)` and `object(_:from:)` check the original Foundation object tree before bridging dictionaries. Application models map these values to their domain types; consumers accepting a validated object check its contract. Safari ingress snapshots the original message before dictionary conversion and maps internal commands directly from validated objects. The generic `Decoder` overload supports already-decoded domain/storage values; it cannot recover keys already merged by a decoder, so raw untrusted JSON must use the `Data` or original-Foundation-value entry points.

The codecs check structure. Browser sender metadata, origin and document identity, response correlation, native authority revisions, ownership, deadlines, account selection, and transaction validity remain explicit checks at their existing boundaries. External RPC data, transaction parameters, and typed-data contents retain their own validators. Native-only approval mutations, approved account descriptors, profile identities, and execution permits are not wire fields.

Inpage providers support ordinary SDK objects, inherited getters and serializers, listener reentry, and request snapshots that remain stable after caller mutation. Admission snapshots preserve native JSON semantics and call caller serializers only during normalization. Detached snapshots shadow inherited `toJSON` methods so later changes to prototype `toJSON` methods cannot rewrite already-normalized payloads. Caller-owned transaction methods and signature targets remain explicit reentry boundaries; their identity, message contents, and operation currentness are checked before and after interactions.

Wire boundaries reject malformed data, accessors, cycles, and failing proxy traps before passing detached records to internal handlers. Private runtime collections and generated payload containers use ordinary JavaScript operations. Arbitrary replacement of global constructors, collection methods, array-index accessors, or reflection functions is outside the supported behavior; the provider does not guarantee recovery from that interference. Inexpensive captured JSON and reflection functions, null-prototype data records, and the snapshot `toJSON` protection remain useful safeguards, not a security boundary within the page's JavaScript realm. Native authorization, origin checks, and approval validation remain authoritative.

Internal transport currentness checks only read installation state; they do not invoke callbacks, mutate provider state, or throw. Transport replies arrive asynchronously through the browser message bridge. Tests for these internal hooks preserve that contract; reentry coverage belongs at caller-controlled inputs and public event listeners.

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

`Scripts/check_swift6.sh fuzz` routes host calls to the VM. Inside the guest,
`npm run test:protocol-fuzz` in `Safari Shared/Inpage Provider` runs the same
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
