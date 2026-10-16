Avoid code comments except for TODOs or essential context.

Use Xcode's default DerivedData location for project builds. Do not pass a
temporary `-derivedDataPath`; macOS build products can leave stale Safari
extension processes running from that location.

Run builds and tests through `Scripts/test_vm.sh run all` (or a selected
`--stage` / `--only-testing` filter). The native umbrella scripts route host
invocations to that VM. Never run wallet app builds, native tests, simulators,
authentication, or helper cleanup directly on the working host. If the VM is
unavailable, report the prerequisite; do not fall back to local execution.
Pure tests of the VM orchestration itself may run on the host without starting
apps, simulators, or accessing Keychain. See `Scripts/vm/README.md`.

Commits that exist only on off-main development branches have not been released.
Do not add or retain migrations, fallback readers, protocol adapters, or
compatibility tests solely for intermediate development versions. Update
producers, consumers, and tests together when changing unreleased formats.
Preserve compatibility with distributed main versions and external protocol
standards. Version numbers and historical development fixtures do not establish
that a format shipped.
