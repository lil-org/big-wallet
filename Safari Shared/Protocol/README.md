# Safari wire protocol

`wire-protocol.json` defines the messages owned by Big Wallet, their shared constants, and browser routing subjects. The dependency-free Node generator emits the browser codec in `Resources/protocol.generated.js` and the native codec in `WireProtocol.generated.swift`.

From the repository root:

```sh
node Scripts/generate_wire_protocol.mjs --write
node Scripts/generate_wire_protocol.mjs --check
```

Edit the definition and regenerate both outputs together. `--write` updates only changed files; `--check` checks without writing. `--root` selects an output repository root and `--definition` selects an alternative definition, for isolated generation tests.

The definition uses references, scalar constant references, exact object fields, dictionaries, arrays, unions, enums, and constrained primitives. An optional field may be absent; it accepts null only when its rule explicitly includes null. String lengths use UTF-16 code units in both generated codecs. Unknown vocabulary, invalid references, recursive definitions, and generated-name collisions fail before outputs are written.

`MAX_JSON_DEPTH` limits nesting to 64 object/array containers, including the message envelope, in both codecs. `depthReservations` gives terminal responses a 63-container budget so their delivery wrappers fit within that limit. Native snapshots retain Foundation decimal values without converting them to binary floating point.

JavaScript exposes `BigWalletProtocol.constants`, `decode(name, value)`, `isValid(name, value)`, and `build(name, value)`. Decoding returns a fresh, deeply frozen snapshot with null-prototype objects. It reads own data properties, rejects accessors and cycles, and does not call payload serializers. `decode` returns null on invalid input, so use `isValid` for a contract that itself permits null. `build` throws for invalid input.

Swift exposes `WireProtocol.Message`, `validate(_:value:)`, and `decode(_:value:)`. Named object contracts also have generated `Codable` wrappers with a validated `json` dictionary. Existing application models adapt these wire values to their domain types.

The codecs check structure. Browser sender metadata, origin and document identity, response correlation, native authority revisions, ownership, deadlines, account selection, and transaction validity remain explicit checks at their existing boundaries. External RPC data, transaction parameters, and typed-data contents retain their own validators. Native-only approval mutations, approved account descriptors, profile identities, and execution permits are not wire fields.
