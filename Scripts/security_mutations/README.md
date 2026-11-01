# Security mutation verification

Run `Scripts/test_vm.sh run all --stage mutation` for the six core mutants, or
`Scripts/test_vm.sh run extended --stage mutation` for all nineteen. Execution is
restricted to the provisioned VM session. The shell entrypoint routes host calls
to that VM. There is no host-native fallback or production mutation switch.

The runner reconstructs one disposable working copy from the active job's hashed
source snapshot. It checks the curated source anchors and assertion markers,
runs an unchanged baseline, applies one literal source mutation, builds, runs its
named witness, restores the source, and checks the complete source inventory.
It finishes by rebuilding and rerunning the restored baseline. Builds use the
same working-copy path and Xcode's default DerivedData throughout; they remain
incremental and serial. A successful build is required before every native test.
Each pristine family build log identifies one default DerivedData root, which is
pinned to its exact working copy, scheme, configuration, and destination. Cached
incremental builds may omit that log line; any re-emitted root must match the pin.
Only that root's
products are searched for one matching `.xctestrun` plan, and the test command uses
that exact plan. Its selected test bundles and app hosts determine the executable
and debug-library hashes. Plan, Info.plist, and executable bytes are checked again
after execution, and their identities are retained with the test results.

Both tiers use Debug. The core set uses macOS package and app tests. Extended adds
two filtered JavaScript tests and one iOS Simulator witness. Ordinary release,
platform, sanitizer, parser-fuzz, and lifecycle verification remain separate
coverage. The complete curated matrix is in `manifest.json`; witness assertions
identify their invariant with `SECURITY-MUTATION[...]` messages.

Only a designated assertion failure from a fully executed witness is a kill.
Every reported failure must carry that invariant marker. Compilation errors,
timeouts, crashes, cancellation, missing or skipped tests, unrelated failures,
and incomplete evidence do not count as kills. All selected mutants must be
killed, with passing before/after baselines, for the stage to pass. A survivor
requires investigation; the runner does not automatically declare it equivalent.

Core and extended campaigns have 3,600- and 7,200-second monotonic watchdogs.
Individual builds have at most 900 seconds, witness runs 180 seconds, and result
queries 60 seconds, bounded by the remaining campaign time. Child processes run
in owned groups; cancellation sends TERM and escalates after five seconds, with
a two-second output-drain bound. Guest orchestration must allow sixty seconds for
finalization. Source restoration and its integrity audit have a forty-five-second
deadline after cancellation. Exhausting any bound leaves failure/incomplete
evidence, never a kill.

The VM stage supplies `--tier`, `--signing`, `--destination-macos`,
`--destination-ios` for extended runs, `--failure-dir`, and `--scratch-dir`.
`BW_TEST_VM_RUN_ID`, `BW_TEST_VM_EXCHANGE`, and `BW_TEST_VM_SOURCE_SHA256` bind the
run to the submitted snapshot. Local mode applies the existing VM verification
signing settings. Apple mode requires the existing unlocked guest signing setup;
its proof key is forwarded only to build commands. Caller compiler overrides and
other credential environment variables are not inherited.

`mutation-report.json` retains source/manifest identities, exact patches, original
source and witness bytes, restoration inventories, commands, executable hashes,
logs, XCTest bundles and parsed evidence, and Node reporter output. The evidence
auditor recomputes classifications and checks exact command scope, signing,
selected tests, and artifact hashes. It exposes `mutationCounts`, deliberately
separate from ordinary XCTest totals. Every selected mutant remains in those
counts when baselines or executions are incomplete; missing proof is invalid
evidence and cannot be credited as a kill.

The `*.test.mjs` files are pure orchestration tests. They use synthetic evidence,
temporary source files, and isolated Node-only assertion/cancellation/timeout
canaries; they never launch wallet apps, native tests, simulators, or Keychain.
