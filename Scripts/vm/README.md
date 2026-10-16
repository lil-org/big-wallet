# Headless VM testing

`Scripts/test_vm.sh run all` builds and tests in an isolated copy of the existing
VirtualBuddy macOS installation. It never opens a host VM viewer, wallet,
simulator, password prompt, or result viewer. The original VM is preserved.

The guest has a virtual audio output with a
[nil sink](https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceoutputstreamconfiguration/sink),
which discards sound on the host. This gives simulator spatial-audio services an output device without
host playback. There is no microphone or other audio input stream.

```sh
Scripts/test_vm.sh doctor
Scripts/test_vm.sh setup
Scripts/test_vm.sh run all
Scripts/test_vm.sh run extended
Scripts/test_vm.sh run all --stage test --configuration Debug \
  --only-testing 'Tests macOS/WindowAuthenticationSessionTests'
Scripts/test_vm.sh run all --stage test --only-testing 'Tests visionOS'
Scripts/test_vm.sh status
Scripts/test_vm.sh stop
```

The existing `check_swift6.sh` and `check_approval_lifecycle.sh` commands route
host invocations here. `check_swift6.sh` is a host-only alias; the guest executes
the shared stage manifest and rejects direct umbrella invocations. Guest execution requires virtual hardware, a root-owned
provisioning identity, the selected console user's graphical session, and a
matching job identity. Missing prerequisites never trigger a host fallback.

The explicit `setup --interactive` option opens one owned window titled
`Big Wallet Test VM — Setup` for one-time guest consent. Default setup and every
`run` command remain headless. Closing that setup window requests VM shutdown.
Interactive setup uses a small cached `.app` wrapper so macOS can identify its
window; it does not replace or modify the normal command-line launcher.

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

The pinned environment is in `environment.json`: Xcode 27.0 (27A266a), Node
24.22.0, npm 11.16.0, jq 1.8.1, iOS 27.0 (24A434), and visionOS 27.0 (24M362).
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

Base provisioning can finish before signing is available. It registers the guest
agent and records the missing signing prerequisites. After the base is verified,
`Scripts/test_vm.sh run all --candidate --stage repository --stage worker` runs
those independent suites in a disposable copy of the candidate. Its report
explicitly identifies partial coverage. A candidate never substitutes for a
fully verified baseline, and unavailable signed stages cannot pass.

Unattended runs require automatic login to the guest test account and an
unlocked graphical session. This is guest-only setup; no host login, screen
locking, permissions, or Keychain settings are changed.

## Existing signing input

Setup does not create signing keys, CSRs, or certificates and does not export
anything from the host Keychain. If signed macOS coverage is available, supply
only an existing Apple Development identity and matching profiles already held
on the host. Otherwise those stages remain explicitly blocked while independent
coverage can run. Entitlements and packaging checks remain intact.

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

## Suites and reports

`all` covers Debug/Release builds and full tests on all three platforms, Safari
JavaScript, generated protocol/bundle checks, all script regressions, the
runner's own tests, Worker tests/type checks/offline validation, Release crypto
performance gates, focused TSan, protocol fuzzing, and Debug/Release approval
lifecycle runs. `extended` adds broader TSan, three fixed 20,000-case fuzz seeds,
and Debug/Release lifecycle soaks of 1,000 sequences × 200 actions.

Selectors are `build`, `test`, `performance`, `tsan`, `fuzz`, `approval`,
`repository`, and `worker`. Repeat `--stage` to select more than one. Dependencies
are included automatically. Repeat `--only-testing` for XCTest classes or
methods, or an entire test target; a target-qualified filter limits testing to
that platform. Provider test files and native suites run serially to bound guest
resource usage. Before each native suite, the runner
shuts down the other selected simulator and waits for the requested simulator
to finish booting. A filtered run is reported as filtered coverage.

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
and lifecycle replay files. Unrelated stages continue after failure; dependent
stages become blocked. Timeouts, missing results, unexpected skips, and empty
native suites cannot pass. Debug crypto skips require corresponding successful
Release gates. Thresholds are not relaxed for virtualization.

If artifact collection is incomplete, the runner keeps the stopped VM clone
and records its path in `retained-vm.json` in the results directory. Later runs
preserve that clone for diagnostic recovery. Clones with fully collected
artifacts are removed even when their tests fail.

`stop` sends the active job a cancellation request over its pinned connection,
permits diagnostic collection, and stops
only the runner-owned VM process. The baseline and original VM remain intact.
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
Editing those harness files or their tests does not require baseline provisioning;
the reported source hash identifies their tested bytes. Direct `guest.mjs`
invocations are rejected; submit jobs through `Scripts/test_vm.sh`.

Changes to the installed bootstrap, its installer, or environment pins require
setup again. Setup applies the update headlessly using the retained guest account
access, then checks installed bootstrap hashes before tests and baseline promotion.
An older prepared VM needs one setup refresh to install this boundary. Interrupted
promotion resumes from its recorded state on the next setup attempt.

Live Safari UI automation, production publishing/deployment, and live paid RPC
probes are outside this runner's suite. Simulator and fixture results do not
establish physical Touch ID/Face ID, Secure Enclave, or real-device behavior.

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
