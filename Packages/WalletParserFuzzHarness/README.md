# Native parser fuzz worker

This test-only executable exercises the production keystore, EIP-712 and Solana
parsers through the existing runtime modules. It uses optimized AddressSanitizer
builds and deterministic structure-aware input generation. It is **not
coverage-guided fuzzing** and does not use libFuzzer.

Run it only through the provisioned VM:

```sh
Scripts/test_vm.sh run all --stage fuzz
Scripts/test_vm.sh run extended --stage fuzz
Scripts/test_vm.sh run all --stage fuzz --parser-fuzz-replay /absolute/path/failure.json
```

The separate package uses `@testable` imports enabled only by its build command.
It neither expands production APIs nor links application, extension, networking,
or flow targets. The closed target graph and worker source are checked before
compilation. The executable never creates live Keychain, wallet repository,
authentication, or network services. Its local C target supplies deliberate
ASan and memory-limit canaries; it is not included in a production product.

The keystore hot loop independently calls the user-import and strict stored-wallet
readers for every input, and checks normalized round trips for keys accepted by
either reader without executing KDFs. Size and PBKDF2 admission boundary cases
record the user-only rejection alongside strict-reader acceptance. The
decryption phase accepts only three bundled synthetic fixtures and eight
enumerated mutations. The KDF parameters cannot be supplied or changed by a
case. Admission boundaries for maximum-cost KDFs are exercised without deriving
their keys. This does not establish arbitrary maximum-cost KDF execution
coverage.

The existing pinned Solana SDK provides a differential oracle for accepted
messages, with stricter native rejection policies recorded separately. Ethereum
uses existing known-answer vectors and metamorphic
properties; no independent Ethereum implementation is added. Fixtures record
their source and contain only published or synthetic test secrets.
Generative and known-answer cases use `PreparedEthereumTypedData`; the 24
resource-boundary fixtures call `EIP712.checkedDigest` once and check the exact
rejection category. Their shapes and acceptance labels come from the existing
`EIP712PreparationTests`, covering every production resource limit. The report
records the selected entry point for each native result.
The Solana size pair uses the same valid legacy message layout at exactly 1,232
and 1,233 bytes, adjusting only the instruction payload and its encoded length.
The admitted fixture must round-trip canonically through the pinned SDK.

The `all` profile executes every corpus entry and 2,000 generated cases for each
parser, plus 24 decryption cases. `extended` uses four fixed seeds with 20,000
cases per parser and seed, plus 96 decryption cases. The plan and audit require
positive cases for all eight generated EIP-712 primitive families under each
seed, flat/nested-struct/struct-array forms, and both sides of every budget.
Both use a five-second
parser watchdog, 30-second decryption watchdog, and 1 GiB monitored RSS ceiling.
RSS is measured by `getrusage` and periodic `ps` sampling; this is watchdog
enforcement, not operating-system memory isolation. The aggregate execution
allowance is ten minutes for `all` and one hour for `extended`, excluding
compilation. An interrupted or exceeded budget fails rather than silently
reducing the planned case count.

Builds use the package's ignored `.build/parser-fuzz-asan` directory. A run-bound
receipt records compiler arguments, source and binary hashes, sanitizer linkage,
the bounded Clang response files used by its C canary, and the aggregate budget.
The audit expands the retained arguments to verify instrumentation. Xcode's
DerivedData setting is not changed. Each phase
copies the evidence required for an independent artifact audit. Exact case
identities and native outcomes are recorded in bounded `cases.jsonl.gz`; the audit
independently repeats expected-result and Solana SDK comparisons. Source hashes
must match the captured VM snapshot manifest and workspace identity. Incomplete, duplicated,
failed, or missing evidence fails the audit.

Failures retain their original input before any reduction attempt. Reduction is
bounded and applies only to unlabeled byte inputs while preserving the failure
classification. Known-answer and explicitly labeled contract cases are not
reduced into unrelated malformed inputs. Replay binds the exact staged artifact
hash and executes exactly one case. Reproduction failures and inability to
reduce an input never erase the original failure.
