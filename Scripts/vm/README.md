# Headless VM testing

`Scripts/test_vm.sh run all` builds and tests in an isolated copy of the existing
VirtualBuddy macOS installation. Default runs never open a host VM viewer, wallet,
simulator, password prompt, or result viewer. The original VM is preserved.

The guest has a virtual audio output with a
[nil sink](https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceoutputstreamconfiguration/sink),
which discards sound on the host. This gives simulator spatial-audio services an output device without
host playback. There is no microphone or other audio input stream.

```sh
Scripts/test_vm.sh doctor
Scripts/test_vm.sh setup
Scripts/test_vm.sh setup --interactive --safari-activation
Scripts/test_vm.sh upgrade-xcode --check
Scripts/test_vm.sh upgrade-xcode
Scripts/test_vm.sh run all
Scripts/test_vm.sh run extended
Scripts/test_vm.sh run all --signing apple
Scripts/test_vm.sh run all --stage safari
Scripts/test_vm.sh run all --stage upgrade
Scripts/test_vm.sh run all --stage asan
Scripts/test_vm.sh run all --stage asan --only-testing WalletAuthorityTests/SecretBytesTests
Scripts/test_vm.sh run all --stage safari --configuration Debug --interactive-safari \
  --only-testing 'Safari UI Tests macOS/SafariLifecycleTests/testInstallAndNativeRoundtrip'
Scripts/test_vm.sh run extended --stage safari --configuration Release
Scripts/test_vm.sh run all --stage safari --only-testing 'Safari UI Tests iOS'
Scripts/test_vm.sh run all --stage test --configuration Debug \
  --only-testing 'Tests macOS/WindowAuthenticationSessionTests'
Scripts/test_vm.sh run all --stage test --only-testing 'Tests visionOS'
Scripts/test_vm.sh run all --stage test --runtime-platform macos \
  --only-testing 'WalletNetworkingTests'
Scripts/test_vm.sh run all --stage runtime --configuration Debug \
  --only-testing WalletNetworkingTests
Scripts/test_vm.sh run all --stage runtime --configuration Debug \
  --only-testing ApprovalCrashWorker
Scripts/test_vm.sh status
Scripts/test_vm.sh stop
```

The default signing mode is `local`. All automated development suites run without
an Apple signing identity, provisioning profiles, or the production RPC proof key.
Runnable macOS and simulator test hosts use ad-hoc signatures. Generic iOS and
visionOS device builds compile without signing. The VM applies these settings
per build invocation; the project's normal Debug and Release settings stay intact.

The `test` stage includes the `WalletRuntime-Package` XCTest scheme in Debug and
Release on macOS, iOS Simulator, and visionOS Simulator. Package selectors use
`WalletDomainTests`, `WalletAuthorityTests`, `WalletFlowsTests`, or `WalletNetworkingTests`, optionally
followed by a class and method. `--runtime-platform` limits only this package
XCTest matrix and may be repeated; omitted platforms remain unverified in a
filtered report. App and Safari selectors keep their platform-specific targets.

Package test builds explicitly enable testability. Each test target must compile
an `@testable` import of its own module; production module builds and ordinary
import API contracts remain separate. The committed
`Scripts/vm/runtime-test-inventory.json` lists every XCTest declaration and its
platform/configuration variants. Run `node Scripts/vm/runtime_inventory.mjs --write`
after adding or moving package tests. The VM checks that inventory against source
before building and requires each selected test to appear exactly once in the
result bundle. Empty, omitted, duplicated, unexpected, or skipped tests fail;
the existing Debug performance skips still require passing Release gates.

`--stage runtime --only-testing WalletNetworkingTests` compiles one package test
target without running it or requiring unrelated package targets to compile.
The four production module names are also accepted. `ApprovalCrashWorker`
validates the closed package dependency graph and builds the standalone harness.
These focused compilation runs do not establish runtime test coverage.

### Address Sanitizer

Both `all` and `extended` include the same focused Address Sanitizer suite:
`asan.focused.runtime` runs the package tests and `asan.focused` runs the macOS
app tests. These stages build and test with Address Sanitizer enabled and Thread
Sanitizer disabled, using serial XCTest execution and the default DerivedData
location. They always use macOS Debug, independently of `--configuration` and
`--runtime-platform`, and use the run's existing signing mode.

The current selection contains 172 runtime tests for secret buffers, Scrypt,
private keys, HD derivation, stored keys, signing lifetime, and private-key imports,
plus 38 app tests for secret handling, lifetime, and alert presentation. The
functional Scrypt vector test is included; timed performance gates are excluded.
The selected app methods are recorded alongside the package tests in
`runtime-test-inventory.json`. Regenerate that inventory after adding or moving
tests in these app classes as well.

Use `--stage asan` to run only these checks and their prerequisites.
`--only-testing` narrows the focused selection by target, class, or method;
unrelated invocations are omitted. An explicit ASan selection that matches no
focused tests fails before execution. Mobile-only vault and UIKit paths are
outside this coverage. Sanitizer instrumentation adds build time, execution time,
and memory use to normal acceptance runs.

Each stage retains its full build/test log, XCTest bundle, summary, and test
inventory. Every expected test must run exactly once and pass without skipping.
The runner checks both XCTest runtime warnings and the complete bounded log for
Address Sanitizer diagnostics and initialization failures; a zero exit status
alone cannot establish a pass. Missing or unreadable audit evidence fails the
stage. Unrelated runtime warnings remain recorded without becoming ASan failures.

The [approval lifecycle guide](#approval-lifecycle-and-crash-tests) describes the
isolated crash worker and its fixture boundaries.

The `upgrade` stage verifies storage and backup compatibility with the confirmed
shipped release **1.0.98 (147)** at
`03b1eb841180081063c6a64e5afe58c76d7f3732`. It runs in both Debug and Release by
default. The self-contained archive in `Tests/Fixtures/ShippedMain/1.0.98-147`
contains 95 unmodified source/license files, including the historical crypto
implementation. Its verifier checks the pinned commit, Git tree/blob proofs,
per-file hashes, and a bounded regular-file inventory before extraction.

The guest compiles those historical sources with thin file-backed storage
adapters, then refuses execution if the binary has an unresolved `SecItem*`
storage call. The old writer produces real wallet JSON, Keychain attributes,
preference values, exported backup text, and signing identities. After that
process exits, the separate `WalletUpgradeHarness` package loads the original
bytes through current storage readers and performs password-authenticated exports
and native approval signing without networking. Subsequent processes reopen a
current mutation, restore the old backups under a different password, and reopen
that restoration. Wrong passwords, unavailable storage, failed writes, and invalid
imports must preserve the original storage bytes.

Plaintext backups restore wallet identities and explicitly re-enabled HD paths;
they do not contain wallet names or custom network settings. Existing-state
upgrade checks cover those preferences separately. App Store entitlement
transitions and physical-device Keychain migration remain outside this harness.
Each stage retains `upgrade-report.json`, individual phase reports, the original
fixture files, the verified archive manifest, compiler command logs, and
`provenance.json` with historical and current source/binary hashes. Missing phases,
checks, fresh-process identities, or unchanged-storage evidence fail the stage.
`python3 Scripts/wallet_upgrade/archive.py --verify` checks the archived proof
without Git; `--check` additionally reproduces it from the pinned Git objects.

Submit stages through `Scripts/test_vm.sh`. The `check_approval_lifecycle.sh`
and `check_wallet_upgrade.sh` stage entry points also route host invocations here.
The guest executes the shared stage manifest and requires virtual hardware, a
root-owned provisioning identity, the selected console user's graphical session,
and a matching job identity. Missing prerequisites never trigger a host fallback.

The explicit `setup --interactive` option opens one owned window titled
`Big Wallet Test VM — Setup` for one-time guest consent. Default setup and default
`run` commands remain headless. Closing that setup window requests VM shutdown.
Interactive setup uses a small cached `.app` wrapper so macOS can identify its
window; it does not replace or modify the normal command-line launcher.

`setup --interactive --safari-activation` prepares Safari consent in a candidate
cloned from a current verified baseline. It requires that baseline's pinned
environment, guest account, and bootstrap tools; finish ordinary setup first if
those prerequisites changed. This focused command accepts no provisioning inputs
and does not stage an installer or regenerate the Xcode archive. It runs the
selected macOS authentication and storage smoke tests, stops that test session,
then builds and installs the local Debug Safari fixture for genuine user activation
without XCTest running. Enable Wallet in Safari Settings > Extensions in the
owned Setup window when prompted.

Preparation records a fresh enabled-state observation from the containing app's
public Safari API, its nonce and process identity, verified product signatures,
and successful process cleanup. The guest and host audit the receipt, and the
host verifies its hashes before promoting the candidate. The previous baseline
remains unchanged if preparation fails. A retry replaces a failed candidate only
when its ownership and fully collected diagnostics are verified; uncertain
diagnostics remain preserved.

After promotion, normal local macOS Safari runtime jobs automatically bind to
the baseline's preparation receipt and run headlessly using the stable prepared
installation. Every run still builds the current source and uses its own fixture
descriptor and data. Its evidence records `activationMode: prepared` and the
preparation receipt identity. The base VM must already have Wallet enabled.
A changed or disabled grant is a failed prerequisite; startup and restart checks
only observe the Wallet checkbox. The suite does not disable or re-enable the
extension and does not claim coverage of that transition. Preparation itself
establishes no lifecycle coverage, and persistence across a cold clone and
subsequent builds must still pass the selected browser tests. It cannot be
combined with `run --interactive-safari`.

The separate `run --interactive-safari` option opens an owned window titled
`Big Wallet Test VM — Safari Activation` for the same disposable clone running
the selected macOS Safari tests. It is accepted only when macOS Safari runtime
tests are selected. At an activation checkpoint, select the Wallet extension's
checkbox in Safari Settings > Extensions inside that window. XCTest observes
the checkbox for up to two minutes without synthesizing the activation click,
then continues the normal provider, native-message, and lifecycle assertions.
This separate assisted workflow can establish initial activation when preparing
an unprepared installation; normal prepared runs require the existing enabled
grant. Keep the window available for activation checkpoints, including browser
restart. Closing it requests normal run cancellation and artifact collection.
The host's Safari and wallet are not involved.

## First setup

The default source is `~/Library/Application Support/VirtualBuddy/tests machine.vbvm`.
Shut down that VM before cloning. `setup` clones it into
`~/Library/Application Support/Big Wallet Test VM/candidate.vbvm`, adds a managed
96 GiB sparse build disk, stages the installer, and attempts a headless boot.
It does not reinstall macOS or reset an existing account. Global `--vm`,
`--state-dir`, and `--xcode` options appear before the command; state location can
also be set with `BW_TEST_VM_STATE_DIR`.

The host also needs Node.js 18 or newer, checked by `doctor`, solely to generate
the planned stage inventory from the source snapshot. Test commands execute in
the guest. The host plan remains separate from guest execution results and
identifies every requested stage if the guest cannot start.

The host keeps a 30 GiB available-capacity reserve. On macOS this includes
purgeable storage that the system can reclaim for user-requested work, matching
the available-space concept in Storage settings. `doctor` reports both that
estimate and currently free bytes. If the macOS estimate is unavailable, the
runner falls back to currently free bytes. Capacity is checked again during runs.

The pinned environment is in `environment.json`, including exact Xcode, Node,
npm, jq, iOS Simulator, and visionOS Simulator versions and build identities.
Xcode is archived into the private host cache, keyed by its pinned version,
build and CodeResources seal. The runner stages an APFS clone of the tar and
its SHA-256; the guest verifies and extracts it, preserving framework symlinks.
Xcode initialization, simulator installation, signing, builds, and tests happen
inside the guest. Keep the default guest DerivedData location. The original 64 GiB disk has Recovery after
its root filesystem, so growing that filesystem would require moving Recovery.
The separate `BigWalletBuild` volume preserves that layout and holds Xcode,
per-user simulator data, runtime downloads, the guest checkout, and the default
DerivedData directory. Installed runtimes still use the system volume; setup
checks its available space before runtime downloads and imports. Existing guest
development directories are preserved when relocated.

Setup installs and updates the guest tools over SSH without opening a viewer.
For an existing account, supply its existing guest password once through
`autologin.passwordFile` in the private input file below. The runner retains a
private copy for later setup updates and test transfers. This is the guest
account password, not an Apple signing credential. SSH uses pinned guest host
keys and never reads the host SSH configuration, SSH agent, or Keychain.
New guest credentials are retained per provisioning request, so failed
candidate updates preserve access to the existing baseline.

Before connecting, setup enables Remote Login only in the idle, runner-owned
candidate and reads its public SSH host keys from that disk. Host SSH settings
and Keychains are unchanged. It also clears the selected automatic-login
account's remembered lock flag so a previous locked shutdown does not relock
the next boot; the account and password are preserved. If the guest has no host keys yet, setup performs
an extra headless boot to generate them, shuts it down, and reads the public
keys before sending any password. Provisioning inputs are transferred into local guest storage over SSH, so the
SSH session does not need access to network volumes. Matching Xcode and runtimes
are reused; large installers are transferred only when needed. Setup can restart
the guest once to apply automatic login. The installer must finish successfully
before readiness checks or tests can start.

For a guest still eligible for Apple's first-boot provisioning, use
`setup --provision-new-account` to create `wallet-test` with a private generated
password and automatic login. This never resets an existing account. An
already configured account needs its existing password. Do not combine new-account
provisioning with `autologin.passwordFile`; that input is for existing accounts.
Encrypted or unsupported guest disks fail with a prerequisite message. Before
attachment, setup reads
the raw image's GPT and APFS metadata and requires every volume to be
unencrypted; unknown or damaged layouts are rejected without exposing the disk
to host mount services. `setup --stage-only` prepares inputs without mounting or
booting the candidate.

Jobs and results live at `/Volumes/BigWalletBuild/Exchange` inside the guest.
Before uploading, the pinned SSH connection waits up to two minutes for the
existing local APFS build volume, matching protected VM identity, and private
Exchange directory. This check is read-only; invalid identities or permissions
fail immediately, and cancellation does not wait for storage to appear.
The host transfers the source snapshot over pinned SSH, publishes the job only
after the transfer completes, and retrieves progress and artifacts through the
same connection. No host directory is mounted in the guest, so rebuilding the
agent does not require renewed network-volume permission. After atomic upload, SSH explicitly starts the registered Aqua LaunchAgent
with `launchctl kickstart -p`, without restarting an existing process. The agent
runs one job and exits; booting the guest or installing the agent does not launch
a leftover job. Per-run claims survive uploads and prevent duplicate execution.
SSH polls atomic supervisor receipts and test results. An uncertain launch reply
is observed without repeating launch. The host accepts a completed result only
after its artifacts have been retrieved.
After a valid receipt or report establishes execution, a report connection that
returns only the known SSH banner-timeout diagnostic may be retried twice, after
5 and 10 seconds, within 60 seconds of the original attempt. Other failures remain
immediate, and retries do not extend run or cancellation deadlines. The host keeps
retry totals and the latest 16 outage records in `guest-transport.json`, including
recovered outages, separately from the guest's test results.

Setup verifies the guest tools and runs its native smoke tests in `local` mode,
then promotes the candidate to a baseline. Missing Apple signing credentials or
the production RPC proof key do not block this verification. An explicitly
requested credential import must still succeed before its provisioning request
is acknowledged.

If setup's native validation has not passed, a base-verified candidate can run
with `--candidate`. It never substitutes for the baseline automatically. Selected
or failed suites remain incomplete; the runner does not waive their checks.

Unattended runs require automatic login to the guest test account and an
unlocked graphical session. This is guest-only setup; no host login, screen
locking, permissions, or Keychain settings are changed.

## Upgrading the pinned Xcode

After installing the intended Xcode on the host, use the upgrade command to
adopt it for VM testing:

```sh
Scripts/test_vm.sh upgrade-xcode --check
Scripts/test_vm.sh upgrade-xcode
```

The existing global `--xcode` option selects the installed bundle and defaults
to `/Applications/Xcode.app`. Put it before the command when using another
location:

```sh
Scripts/test_vm.sh --xcode /Applications/Next/Xcode.app upgrade-xcode --check
Scripts/test_vm.sh --xcode /Applications/Next/Xcode.app upgrade-xcode
```

`--check` inspects the selected Xcode and the proposed upgrade without changing
files, creating caches, or starting a VM. It reports the installed toolchain
identity and the XCUIAutomation image identity required by the iOS Safari
synchronization hook. Inspection alone does not establish that the new image
supports the hook or that the test suites pass.

An upgrade updates the checked-in Xcode version/build and the hook's matching
XCUIAutomation identity. It preserves the pinned simulator runtimes, Node,
npm, jq, and other environment settings. The old baseline VM and its matching
`baseline.json` record are retained together before replacing that baseline.
Keep this pair together when investigating a failure; a VM bundle without its
matching environment and verification record is not a usable verified baseline.
The original VirtualBuddy VM remains unchanged.

Verification runs through the normal VM runner in this order:

1. Setup provisions the selected Xcode and runs the native setup smoke tests.
2. The focused iOS Safari synchronization-hook tests verify the new framework
   identity and method behavior.
3. The macOS and iOS Safari installation/native-message roundtrips exercise the
   browser and extension with the new toolchain.
4. `run all` completes the full matrix with local signing.

A passing setup smoke test makes the new baseline available for further
verification. It does not make the complete Xcode upgrade verified. Changed
pins, a prepared candidate, or successful focused tests also leave the upgrade
incomplete until every required stage, including the full local matrix, passes.
Reports identify the source snapshots actually tested.

Repeating `upgrade-xcode` reuses safe setup progress and matching cached inputs,
then verifies the current source again. A previous passing report does not waive
verification of subsequent source changes. Failures preserve diagnostics and
the old baseline pair; the command does not roll back files or VMs automatically
and does not create a commit. Inspect the reported setup or test result and its
logs to distinguish provisioning, hook compatibility, browser prerequisites,
test failures, and incomplete artifact collection before retrying.

Safari activation is an independent prerequisite. If a live Wallet extension
grant is unavailable after the toolchain change, the upgrade stops with that
prerequisite. A baseline without Safari preparation can first complete the
native Xcode upgrade, then stops for activation before browser verification.
Complete the existing explicit guest interaction workflow, then
repeat the upgrade:

```sh
Scripts/test_vm.sh setup --interactive --safari-activation
Scripts/test_vm.sh upgrade-xcode
```

Use the same global `--vm`, `--state-dir`, and `--xcode` values for recovery as
for the upgrade. Enable Wallet in the owned guest Setup window when prompted;
the upgrade does not synthesize consent or turn an assisted run into a headless
verification result.

Allow space for the new uncompressed Xcode archive, its guest staging copy,
the extracted new Xcode, and the previous guest Xcode retained by provisioning.
The old baseline and diagnostic clones also retain disk blocks. APFS clones
share existing blocks initially, but installing Xcode and running the full
matrix allocate additional blocks; adding the sizes printed by `du` for cloned
VM bundles overstates their unique host usage. The host's 30 GiB capacity reserve
still applies, and passing that check does not prove that the guest's 96 GiB
build volume has enough free space for extraction and builds. Capacity failures
require diagnosis before retrying; the upgrade does not discard baseline
backups or diagnostic clones to make room.

## Existing signing input

Apple signing is optional. `run all --signing apple` uses the project's normal
entitlements and signing settings and requires an existing Apple Development
identity, matching profiles, and the production RPC proof key in the guest.
Missing credentials block that mode; it never falls back to local signing.

Setup does not create signing keys, CSRs, or certificates and does not export
anything from the host Keychain. Supply only existing signing inputs when you
want this additional coverage. Normal release packaging and credential checks
remain intact.

Keep input outside the checkout. For example, a private `provision-input.json`:

```json
{
  "consoleUser": "wallet-test",
  "autologin": {"passwordFile": "guest-account-password.txt"},
  "signing": {
    "p12Path": "development.p12",
    "p12PasswordFile": "p12-password.txt",
    "keychainPasswordFile": "guest-signing-keychain-password.txt",
    "proofKeyFile": "AlchemyJWTRequestProofKey",
    "profiles": ["app.provisionprofile", "extension.provisionprofile", "helper.provisionprofile"]
  }
}
```

The `signing` section is optional. Paths are relative to the input directory or absolute. Setup copies
only the specified files into private provisioning staging. Values are never
printed. The guest creates a dedicated signing keychain; do not supply your
whole host Keychain or wallet containers. `autologin.passwordFile` enables login
using the existing guest password and never resets it.

Provisioning exchanges live under the private `setup` state directory, separate
from archived test `results`. Keep them private while bootstrap is incomplete.
Successful baseline promotion removes applied staging packages; original
credential input files remain where you supplied them.

Explicit provisioning inputs are staged as a pending package with an ID and
selected guest account. The guest installer records that ID only after the
requested inputs are applied. Setup checks the applied receipt and account
before verification or promotion; a healthy older installation cannot satisfy
a new request. Missing signing inputs remain an unavailable capability and do
not prevent an otherwise completed package from being acknowledged.

Running setup again without new inputs reuses the pending package, including
its staged input files and selected account. It does not replace the package
with defaults. Pending first-boot account creation also retains its intent and
existing private password; retries do not generate a replacement password or
reset an existing account. If guest tools or environment pins changed while it was pending,
setup preserves the old package and stages its retained inputs with the current
tools as a new request. Explicit new inputs supersede the pending
request; unapplied packages remain available. Promotion removes only packages
whose ID was confirmed as applied.

Without a pending request or new inputs, setup validates the current guest and
does not require another installation. The selected account defaults to the
recorded account, or `wallet-test` for a new candidate. `--guest-user` and an
explicit `consoleUser` in the input file must agree. Both setup validation and
baseline reuse require that account; setup never silently switches accounts.

```sh
Scripts/test_vm.sh setup --provision-config /private/path/provision-input.json
```

Alternatively, `--proof-key-bundle '/path/to/Big Wallet.app'` imports just the
already-bundled request-proof resource after validating its checked-in SHA-256.
It does not query the host Keychain. Exact simulator installer DMGs can be
supplied with `runtimes` entries containing `platform` and `dmgPath`; otherwise
the guest downloads the pinned versions from Apple and checks their build IDs.

## Approval lifecycle and crash tests

Run from the repository root on the host:

```sh
Scripts/test_vm.sh run all --stage approval
Scripts/test_vm.sh run all --stage approval --configuration Release
Scripts/test_vm.sh run all --stage approval --configuration Debug --approval-arg=--soak --approval-arg=--seed --approval-arg=42
Scripts/test_vm.sh run all --stage approval --configuration Debug --approval-arg=--replay --approval-arg=/path/to/replay.json
```

The default run checks mandatory scenarios and process-crash boundaries, explores
bounded deterministic races, and runs 32 seeded sequences of 64 actions,
alternating native and popup approval. `--soak` defaults to 1,000 sequences of
200 actions; `--seed`, `--sequences`, and `--steps` select a bounded random run
through `--approval-arg`. The VM retains failure artifacts in the printed results
directory.

The mandatory corpus also runs twelve combined persistence-recovery cases across
native/popup approval and Ethereum/Solana: a 17-byte partial write followed by
`ENOSPC`, an `EIO` after broadcast-checkpoint rename, and an `EIO` before completion
publication after RPC acceptance. Each case proves the exact request, process,
operation, and injected errno before restarting or disconnecting. Recovery and
stale approval replay cannot sign or dispatch again. A pre-checkpoint popup retry
requires fresh consent within the original deadline; native interruption requires
a new browser request. Published checkpoints retain their original transaction
identity through repeated recovery and delivery, without restoring permissions.
These errors are injected through the worker's file-operation hooks; the tests do
not fill the guest disk. Failed-result gates run after the store releases its lock.
Inspection retains the current wallet snapshot while a wallet mutation is active,
so diagnostic reloads cannot invalidate that mutation's readiness token.

Every default approval run includes bounded systematic exploration with at most
256 traces, one preemption, one fault, two overlapping requests, and 64 transitions. Extended
runs add a dedicated 4096-trace pass with two preemptions, two faults, three
overlapping requests, and 128 transitions. Each request is parked at an acknowledged
native task boundary before exploration starts. A second approved request runs
in another Safari profile; the extended pass also holds a third admission from
another origin. Recovery cannot grant fresh consent to that queued request.
The report records observed request overlap and applied faults for each scenario,
and the auditor rejects missing evidence. The existing random soak remains separate.
`--approval-arg=--systematic`, followed by `--approval-arg=all`, `extended`, or
`off`, selects a diagnostic profile; `--systematic-only` and `--trace-limit` are
also forwarded through `--approval-arg`. An unfinished frontier or missing
mode/provider/template evidence fails the run and retains
`systematic-coverage.json` beside its replay artifacts.

The crash worker lives in the separate `Packages/WalletRuntimeHarness` package
and runs without launching the wallet app or Safari extension.
Its guest build enables testability only for that invocation; app products never
depend on this package or its fixture code. The prebuild validator rejects app or
extension entry points, copied resources, plugins, production proof material,
entitlements, and production dependencies on test support. Fixtures use real
module authorization with fake credentials and protected-key storage in their
disposable directory.

The worker's two process roles share only a disposable test directory. Wallet
records, metadata, networks, authentication outcomes, and RPC responses are
explicit fixtures. Production routing, scoped authentication, approval, signing,
and durable persistence execute against those dependencies.

The Node parent runs the actual provider, content script, service worker, and popup scripts in separate VM contexts. It controls message delivery and test clocks, records signing and simulated RPC effects outside the native processes, and kills only its own children at acknowledged checkpoints. Restarts retain the same test files and receive new process identities. A failure retains its attempted action prefix, seed, event ledger, browser trace, and storage snapshot; reduction attempts preserve the failing invariant and are capped at 200. Replay executes the production scenario again. Systematic replay requires the exact enabled and selected actions, and a minimized witness must reproduce twice before it is marked stable. Random replay consumes exactly the recorded scheduling decisions and transport fault targets; a fresh seeded run explores subsequent actions after a fix.

Failure artifacts also record captured source snapshot and worker binary hashes,
the original witness, durable observations, and external effects. Replay against
newer source records that source separately without replacing the original identity.

Random permanent message drops apply to extension/native transport boundaries. Same-document DOM events can be delayed, duplicated, or reordered; document loss is modeled by navigation or replacement. Arbitrary permanent DOM-event loss is outside the progress guarantee and may leave a provider promise pending before the extension receives it. Replay retains explicit scheduling and fault choices; automatic polling can vary with process scheduling, so its full trace is diagnostic rather than a byte-for-byte replay requirement. A failure that does not reproduce is reported as such.

The harness checks the [runtime execution and recovery guarantees](../../Packages/WalletRuntime/README.md#execution-and-recovery).
Unexpected exits, missing checkpoints, malformed replies, and watchdog timeouts
fail the harness.

Process kills do not simulate power loss; the persistence disk-model tests cover synchronization ordering separately. Browser APIs and authentication are simulated here. Actual Safari suspension, sender metadata, rendering, biometrics, and protected vault keys still require device testing.

## Suites and reports

Native builds use Xcode's default DerivedData inside the guest and disable coverage
collection. Simulator destinations come from the pinned guest runtimes. Validating
the oldest supported OS versions requires those runtimes or devices separately.

`all` covers Debug/Release builds and full tests on all three platforms, Safari
JavaScript and real Safari UI lifecycle tests on macOS and iOS Simulator, generated protocol/bundle checks, all script regressions, the
runner's own tests, Worker tests/type checks/offline validation, Release crypto
performance gates, focused TSan, protocol fuzzing, and Debug/Release approval
lifecycle runs. `extended` adds broader TSan, three fixed 20,000-case fuzz seeds,
Debug/Release lifecycle soaks of 1,000 sequences × 200 actions, and ten iterations
of every selected Safari lifecycle scenario in Release on both browser platforms.

Both signing modes run the same selected tests, performance thresholds, crash
scenarios, and result audits. Local native unit-test verification removes production
entitlements, App Sandbox, and Hardened Runtime settings from its ad-hoc products.
Safari UI builds use their dedicated fixture settings for browser extension loading. The
native tests exercise injected storage, authentication, and RPC dependencies;
source and packaging contract tests continue checking the production entitlement
files. Actual OS authorization of shared Keychain or app-group access is outside
that fixture coverage.

Local builds remove any stale `AlchemyJWTRequestProofKey` resource and omit it.
They never read a production proof key or bundle a substitute. The omission is
allowed only for a verified VM build session with the local build settings;
archive and deployment actions are rejected. Production bundling still requires
the pinned key, and release artifact validation rejects these keyless products.

Reports record the signing mode and credential coverage separately from suite
results. A complete `local` run establishes the full automated development matrix;
it does not establish Apple signing, production proof-resource packaging, or
distribution readiness. `apple` mode adds builds using the provisioned credentials.
The Safari stages additionally require the real browser to load the extension,
complete provider and native-message handshakes, and pass every selected lifecycle
scenario. They use isolated test wallet, authentication, and RPC fixtures where
required for deterministic credential-free execution. Browser results are reported
separately from Apple signing and production entitlement coverage. Neither signing
mode establishes physical biometric, Secure Enclave, or release-distribution behavior.

macOS Safari builds use Xcode's default DerivedData location. Each browser stage
copies its complete signed app into the guest's private
`~/Applications/BigWalletSafariVM/<run-id>/<stage-id>/` directory, verifies the
copy, and launches the wallet and helper by their exact installed URLs. Cleanup
records removal of both the installed and build-product extension registrations.
After native cleanup succeeds, it removes the installation only while its ownership
marker still matches. Failed or unconfirmed cleanup retains the installation and
records its path and reason in the finalization report.
For [Apple's macOS 27 issue 183044008](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes), local tests keep Safari running after
enabling unsigned extensions, rebuild the containing app in default DerivedData,
then verify and replace the owned installation before enabling the extension.
Successful intermediate soak iterations reuse Safari after closing fixture pages
and approvals; wallet and helper authentication still starts fresh. Profile tests,
failed iterations, and each method's final iteration fully terminate the browser.
XCTest's default and maximum allowances are ten minutes per scenario iteration,
so a ten-iteration method has a 100-minute allowance. The browser stage still has
a two-hour normal or six-hour soak limit, and individual UI waits stay bounded.

The pinned iOS 27.0 (24A434) runtime can leave XCTest waiting for Safari's
animation-idle callback after the app's event loop is idle. The iOS Safari
UI-test target uses a private XCTest hook restricted to the pinned XCUIAutomation
image and method ABI. For `com.apple.mobilesafari` only, it calls the original
quiescence implementation with animation waiting disabled; the event-loop wait,
timeouts, and other applications' synchronization remain unchanged. An unsupported
framework or replaced hook fails setup instead of falling back.

Reports identify this as `safari-event-loop-only` synchronization, with per-scenario
before/after receipts proving Safari pre/post interception and unchanged forwarding
for other applications. macOS reports `xctest-default`. Safari controls must expose
stable geometry and the expected UI state before interaction. These results do not
establish that Safari's own animation-idle notification works. The hook is linked
only into iOS test bundles, never the wallet or extension. Normal runner audits
reject animation-idle log warnings, XCTest runtime warnings, missing hook proof,
or failed cleanup, including during the ten-iteration soak.

On macOS 27.0.1 (26A434), Safari rejected XCTest's extension-activation click with
its security alert about an app or service interfering with clicking. The test
retains the screenshot and accessibility evidence and fails with an explicit
interactive-guest prerequisite; it does not skip the case or bypass the control.
See [Apple's supported troubleshooting steps](https://support.apple.com/en-us/108379).
`run --interactive-safari` provides genuine user activation checkpoints in the
active test guest. Its evidence records `activationMode: interactive`, including
each checkpoint's scenario, iteration, requested state, and observed-state times.
The audit rejects missing or mismatched modes and incomplete checkpoints. A
passing assisted run does not establish unattended coverage, and activation
alone does not establish browser-restart coverage.

Plain `setup --interactive` does not prepare Safari activation; use the explicit
`--safari-activation` workflow above. Safari's unsigned-extension permission is
separate from the Wallet checkbox, and
[Apple resets unsigned-extension support when Safari quits](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension).
The assisted run keeps the same clone and product active while the user performs
each required click. If Safari rejects the genuine click while XCTest is
observing, that remains a failed prerequisite; no private preference or API
overrides Safari's control. Prepared clones have passed selected headless Debug
install/native-roundtrip and browser-restart checks. The base VM's enabled grant
is a test prerequisite. Extension disable/re-enable testing is outside the suite;
all remaining scenarios retain their normal provider, native-message, and
lifecycle assertions.

Apple-signed macOS Safari products preserve their original app-group and Keychain
entitlements and signing identities. The wrapper adds a temporary sandbox file
exception for the exact per-run test-control directory, then re-signs the embedded
helper, extension, and containing app using their existing identities. Reports
identify this additional test-only file access explicitly; these results establish
coverage of modified Apple-signed test products, with distribution validation kept separate.

Selectors are `build`, `test`, `runtime`, `performance`, `tsan`, `asan`, `fuzz`, `approval`, `safari`,
`repository`, and `worker`. Repeat `--stage` to select more than one. Dependencies
are included automatically. Repeat `--only-testing` for XCTest classes or
methods, or an entire test target; a target-qualified filter limits testing to
that platform. Provider test files and native suites run serially to bound guest
resource usage. Before each native suite, the runner
shuts down the other selected simulator and waits for the requested simulator
to finish booting. A filtered run is reported as filtered coverage.

Safari tests use the `Safari UI Tests macOS` and `Safari UI Tests iOS` targets.
Target, class, and method selectors work with `--only-testing`; the runner derives
the required browser scenario inventory from that selection. Safari builds use
`build-safari.<platform>.<configuration>` stages, followed by
`safari.<platform>.<configuration>`. The extended Release stages are
`safari.soak-macos.release` and `safari.soak-ios.release`. A repeated scenario must
pass every iteration; repetitions do not retry or conceal failures.

iOS Safari scenarios enable Reduce Motion and Prefer Cross-Fade Transitions and
select the Top tab layout through Settings. They verify both motion preferences
through public UIAccessibility APIs and the upper address bar before exercising
the fixture. These runs cover the expanded Top layout; Compact layout is outside
this test configuration.

Website origin reservations are stored privately per run and platform.
Apple-signed builds share reservations across configurations because they share
permission storage; local builds keep reservations per configuration. Later stages
reject previously used origins, keeping the normal Release run and soak isolated
while preserving wallet and grant storage for restart scenarios. Control and RPC
endpoints use a separate transport.
If XCTest aborts before a scenario can finish, the controller preserves that
scenario as failed and requires cleanup of its verified native processes before
admitting the next scenario. Later successes cannot erase the aborted case.

The native handshake requires Safari website ingress for the exact scenario origin,
including tab, frame, document, privacy, and profile metadata. Installation and
Ethereum-message scenarios also prove shared-path lock exclusion: the extension
holds a dedicated probe lock using the production `CrossProcessFileLock`, the
foreground app observes contention, and the app acquires it after the extension
releases it. The controller requires ordered acknowledgments from distinct native
processes. This probe does not hold the wallet's request-store or vault locks.

UI automation runs in the guest's unlocked graphical session. The verified guest
installer uses Apple's `automationmodetool enable-automationmode-without-authentication`
to configure the dedicated VM for unattended UI testing. It then runs the tool
without arguments as the selected console user and requires the status to say
authentication is not required. Automation Mode itself may be disabled until
XCTest starts; that is distinct from requiring an administrator password. This
does not change TCC databases, Accessibility grants, or host security settings.
Any remaining one-time guest consent must be completed through `setup --interactive`;
a headless run cannot substitute for missing consent. Browser setup, extension activation,
and missing UI elements fail the stage instead of skipping coverage. Whole-guest
macOS screen lock/unlock is not covered because the unattended runner cannot
unlock the guest. Simulator results do not establish physical iPhone lock behavior.

Wallet access expires after 15 minutes without interaction. Automated access tests
use a monotonic test clock and injected lifecycle notifications; the iOS Safari
background/foreground scenario also verifies that the containing app stays locked
while the extension completes its independently authenticated request.

Before accepting a release with access-lifecycle changes, manually check screen
lock/unlock inside a disposable interactive VM: unlock the wallet, leave an
unapproved request open, lock the guest, and unlock the guest. The wallet must
show its Unlock screen, the unapproved request must be rejected, and no old
password, import draft, or secret presentation may return. Repeat with an already
accepted transaction and verify that recovery settles it without another send.
Ordinary macOS application switching must preserve access until its idle deadline.
Record the tested macOS version and result separately from automated evidence;
supported protected-data, sleep, and session-switch notifications do not establish
coverage of every graphical screen-lock configuration.

Secret-lifetime regressions exercise real AppKit field editors and UIKit text
input, including retained undo managers, prompt confirmation/cancellation, normal
navigation, and lock teardown. Import undo/redo must still work before teardown;
unrelated controls must retain their history afterward. Preview tests cover
explicit invalidation, cancellation during derivation, and late session creation.
Invalidation drops the session's retained HD wallet and rejects late results;
an in-progress derivation may finish using its local reference. These checks
establish reference lifetime and UI cleanup, not guaranteed erasure of every
temporary Swift or framework memory copy.

Local macOS Safari can require the dedicated guest account password when enabling
unsigned extensions. For runs whose captured plan includes that browser suite, the
existing pinned SSH transport stages the already-retained guest password in a
run-specific private file after verifying the guest session. The authenticated
test controller uses it only for Safari's guest authentication sheet and scoped
guest clipboard input. It is excluded from source snapshots, job JSON, command
arguments, logs, and exported artifacts, and is removed on cancellation or final
artifact collection. Apple-signed runs and iOS-only selections do not receive this
UI credential. This uses the VM account password already required for SSH setup;
it does not require Apple signing credentials or change host authentication.

Approval `--replay` files are copied into the guest exchange automatically.
Worker executables, failure directories, and scratch directories are owned by
the guest runner; host overrides for those paths are rejected.

Each run snapshots tracked changes and nonignored source, excluding credentials,
dependencies, and build outputs. Its manifest hash identifies the bytes tested.
Guest checkout changes cannot write back to your repository. Each job uses a
disposable VM clone; Xcode and installed runtimes come from the verified baseline,
or from the base-verified candidate when explicitly selected with `--candidate`.

The printed results directory retains `artifacts/result.json`, individual logs,
`.xcresult` bundles, test and skip counts, resource measurements, protocol seeds,
and lifecycle replay files. Safari stages also retain a `<stage>.safari.json`
browser evidence ledger bound to the run, stage, platform, configuration, and
signing mode. Each expected XCTest case and each scenario iteration must be present
exactly once and pass, and the ledger must record successful final cleanup. Partial
ledgers written before cleanup, missing ledgers, failed handshakes, duplicate entries,
and unexpected tests cannot pass. Unrelated stages continue after failure; dependent
stages become blocked. Timeouts, missing results, unexpected skips, and empty
native suites cannot pass. Debug crypto skips require corresponding successful
Release gates. Thresholds are not relaxed for virtualization.

Native test commands disable Xcode's verbose system diagnostics with
`-collect-test-diagnostics never`. Xcode's failure-time simulator diagnostic
collector can remain blocked after XCTest has finished inside the headless VM.
Test logs and `.xcresult` bundles are still retained and audited; failures,
unexpected skips, missing results, and performance requirements remain enforced.

Stale generated bundles remain failed checks, with their rebuilt files exported
under `artifacts/generated/<stage-id>/` and their paths and SHA-256 recorded in the stage's `generatedArtifacts` result.

If artifact collection is incomplete, the runner keeps the stopped VM clone
and records its path in `retained-vm.json` in the results directory. Later runs
preserve that clone for diagnostic recovery. Clones with fully collected
artifacts are removed even when their tests fail.

For test jobs, `stop` sends a cancellation request over the pinned connection,
permits diagnostic collection, and stops only the runner-owned VM process.
Collection waits are bounded by phase: 20 seconds before a guest job is observed,
10 minutes for a running job to finalize, 30 minutes for export, and 15 minutes
for extraction, with a 55-minute overall collection limit. Failed transports and
disk-capacity failures stop collection immediately. A second `stop` or interrupt
requests prompt shutdown instead of waiting for collection. Cancelled or timed-out
runs retain that outcome even when their artifacts finish exporting.
Safari runtime wrappers have up to five minutes after a termination signal to
finish cleanup and diagnostics; exiting sooner cancels that allowance. Other
stages retain their five-second termination grace.
The baseline and original VM remain intact.
Preparing runs are visible to `status` and accept `stop`; source snapshot and
plan creation finish for reporting, and cancellation is checked before cloning
and VM launch. A clone already being copied finishes before safe cleanup.
Do not open a runner-owned VM in VirtualBuddy while a headless run owns it.
An interrupted initial copy is rebuilt on the next setup attempt; prepared
candidates and interrupted test logs are retained.
An older baseline remains available after successful replacement.

The installed bootstrap consists of `VMGuestAgent`, `guest_runner`, and
`guest_bootstrap.mjs`. It verifies the guest session, storage, and complete source
snapshot before importing `guest.mjs` from the materialized checkout. The test
manifest, stage execution, and result auditor run from that same captured source.
Job identity, source and bootstrap hashes, execution kind, and the profile label
remain in the outer job envelope. Stage selectors, XCTest filters, configuration,
and approval arguments live in `payload`. The bootstrap checks only that the
profile is a nonempty bounded label and the payload is an object; the captured
harness validates supported profiles and payload options. Adding a harness option
or profile therefore does not change the installed bootstrap or report format.
Editing those harness files or their tests does not require baseline provisioning;
the reported source hash identifies their tested bytes. Direct `guest.mjs`
invocations are rejected; submit jobs through `Scripts/test_vm.sh`.

Changes to the installed bootstrap, its installer, or environment pins require
setup again. Setup applies the update headlessly using the retained guest account
access, then checks installed bootstrap hashes before tests and baseline promotion.
Producers and consumers use the current job format together without accepting
earlier development formats. Interrupted promotion resumes from its recorded
state on the next setup attempt.

Production publishing/deployment and live paid RPC probes are outside this
runner's suite. Simulator and fixture results do not
establish physical Touch ID/Face ID, Secure Enclave, or real-device behavior.

## Recovering retained diagnostics

After freeing enough host space, collect artifacts from a stopped run that has a
`retained-vm.json` receipt:

```sh
Scripts/test_vm.sh recover-artifacts RUN_ID
```

Recovery starts only that retained VM, using the credential scope and exact SSH
pin file recorded before the original launch in `guest-access.json`.
Later baseline or candidate setup does not change this binding.
It checks the original job and source identity,
rejects any still-live recorded runner, and reads the existing artifact directory.
It does not mount the guest disk on the host, provision the VM, upload source,
launch a test job, or change the original job's stop records. Missing credentials
or a missing access receipt or pin file block recovery instead of guessing an
account or establishing new trust.

The command prints a separate `recovery-*` results directory. Its
`recovered/artifacts/` directory contains the collected logs, `.xcresult` bundles,
and raw guest `result.json`; `artifacts/result.json` reports collection status.
The original run's result, source manifest, job, and retention receipt stay
unchanged. An unfinished guest report is retained as partial diagnostic evidence.
Successful collection never changes the original test outcome or establishes
passing suite coverage. The stopped VM remains retained after collection.

Admission requires actual free space for both the downloaded archive and extracted
files, in addition to the configured host reserve. `collection-capacity.json`
records the host available-capacity API's estimate and actual free bytes; purgeable
space alone does not admit an artifact transfer. Recovery validates bounded
archive contents before publishing them. The default total timeout is one hour;
`--timeout SECONDS` selects another bound. `status` shows recovery progress, and
`stop` cancels the collector and shuts down only its owned VM process. These
operations use the recovery attempt's own stop and status files.
A retry reconciles a stopped, interrupted recovery attempt before collecting;
it reclaims abandoned scratch archives and partial extractions before checking
capacity. Workers retain a scratch lock through stderr, so live writers block
cleanup. Reports, published `recovered/` output, and the retained VM stay intact.

## Testing the runner itself

These checks are safe on the host: they exercise fixtures and subprocess
plumbing without launching wallet apps, simulators, or Keychain operations.

```sh
python3 -m unittest discover -s Scripts/vm/tests -p 'test_*.py'
node --test Scripts/vm/tests/*.test.mjs
```

The headless launcher and guest agent are compiled separately with `swiftc`
and ad-hoc signed. No wallet Xcode target or host signing identity is used for
that bootstrap. They use public Virtualization APIs, not VirtualBuddy's viewer
automation. Pinned SSH carries job control and results; the guest LaunchAgent
preserves the graphical session required for native tests. There is no separate
socket control channel. Missing launch receipts and supervisor exits without
results have a 30-second observation grace; receipts alone cannot establish success.
