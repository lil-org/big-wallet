# Alchemy JWT issuer

This Cloudflare Worker issues RS256 JWTs for direct Alchemy JSON-RPC requests.
It is not an RPC proxy: wallet clients contact the Worker only to acquire a
JWT, then call keyless `https://<network>.g.alchemy.com/v2` endpoints directly
with `Authorization: Bearer <JWT>`.

The production endpoint is exactly:

```text
https://api.lil.org/v1/alchemy/jwt
```

Requests for another host, port, path, query, or URL containing user
credentials are rejected. A direct cleartext request that reaches the Worker
is rejected before request parsing or authentication. The account-level HTTPS
redirect described below should normally handle cleartext traffic first.

## HTTP contract

The only accepted request is:

```http
POST /v1/alchemy/jwt
Content-Type: application/json
X-Lil-Alchemy-Proof: <unpadded-base64url HMAC-SHA256>

{"timestamp":1784558400,"nonce":"AAECAwQFBgcICQoLDA0ODw"}
```

The complete request body is capped at 1 KiB and must contain exactly the
`timestamp` and `nonce` properties; their JSON order is irrelevant. `timestamp`
is a nonnegative integer Unix second no more than 300 seconds behind or ahead
of the Worker clock. `nonce` is the canonical unpadded base64url encoding of
exactly 16 random bytes.

The proof is the canonical unpadded base64url encoding of the 32-byte
HMAC-SHA256 output over this exact byte sequence:

```text
LIL-ALCHEMY-JWT-PROOF-V1\nPOST\nhttps://api.lil.org/v1/alchemy/jwt\n<exact raw request body bytes>
```

The three displayed `\n` sequences represent single ASCII LF bytes. There is
no separator or trailing byte between the final prefix LF and the raw body.
Clients must sign the exact bytes they send, not a parsed or re-encoded JSON
object. Missing, malformed, stale, or incorrect request proofs receive the same
generic `401`.

This shared proof key is deliberately state-free and adds no network
dependency to issuance. Because the same key is shipped in supported apps, it
can eventually be extracted and must not be described as device, account, or
app attestation. The timestamp bounds replay of a captured request, but exact
replays inside the five-minute window remain valid because the Worker stores no
nonce state.

Successful responses retain the original contract:

```json
{
  "token": "<jwt>",
  "issuedAt": 1800000000,
  "expiresAt": 1800021600
}
```

Production uses a six-hour (`21600` second) lifetime. The Worker accepts only
canonical configured lifetimes from one hour (`3600`) through six hours
(`21600`), inclusive. The JWT header contains only `alg`, `typ`, and Alchemy's
`kid`; its payload contains only `iat` and `exp`. The live validator requires
the production six-hour lifetime.

Every JSON response uses:

- `Cache-Control: no-store`
- `Content-Type: application/json; charset=utf-8`
- `Strict-Transport-Security: max-age=31536000`
- `X-Content-Type-Options: nosniff`
- `X-Alchemy-JWT-Worker-Version: <Cloudflare version UUID>`

The Worker intentionally emits no CORS headers. Version metadata is validated
before issuance or authentication. Missing or malformed metadata fails closed
with a generic `500` and omits the untrustworthy version header.

The Worker has no per-client counter or durable identity state. The request
proof is an admission check, not an accounting or quota boundary.

## Availability and monitoring policy

The Alchemy app intentionally has no hard throughput limit, spend limit, or
automatic shutoff. Alchemy auto-scaling therefore has no configured ceiling.
This preserves wallet RPC availability during legitimate bursts, but it also
means the request proof is not a spend-control mechanism.

The Alchemy alert policy must send every alert to all active owners/admins and
include:

- an error-rate alert at `2%` over a `10m` window; and
- compute-unit usage alerts whose thresholds are the absolute CU values
  calculated from `50%`, `75%`, and `90%` of the current monthly paid-plan CU
  allocation. Enter those resulting absolute CU values, not percentages.

These alerts notify operators only. They must not automatically throttle
traffic, change keys, disable the Worker, or mutate deployment state. An
operator reviews the aggregate signal and makes any incident change explicitly.

Automatic tracing and Cloudflare invocation logs are explicitly disabled. The
Worker emits only its redacted internal-failure category; successful issuance
and expected client failures are not logged. Do not add request bodies, nonces,
proofs, JWTs, IP addresses, devices, or key identifiers. There is no documented
or enforced downstream Alchemy quota per device or per JWT; all issued JWTs
retain the configured Alchemy app's downstream access.

## Pinned local toolchain

Use the exact Node release in `.nvmrc`; this project also pins the npm version
in `package.json` and rejects other Node major versions during installation.

```sh
nvm install
nvm use
node --version
npm --version
npm ci
```

Expected versions are Node `24.18.0` and npm `11.16.0`.

Run the complete local suite:

```sh
npm run types
npm run check
npm test
npm run validate:self
npm run validate:live -- --dry-run
npm run deploy:dry-run
npm run startup
```

`wrangler types` generates `worker-configuration.d.ts` from `wrangler.jsonc`,
including both required secrets and the version metadata binding. Do not
hand-edit that file.

Worker tests generate ephemeral RSA keys inside the local Workers runtime.
Tool tests use only ephemeral keys and local fake HTTP responses. No production
secret is required for either suite.

## Existing signing-key bundle and preflight

This remediation rollout does **not** rotate the Alchemy signing key. Reuse the
existing unencrypted RSA-2048 PKCS8 private key, its matching registered SPKI
public key, and the existing `ALCHEMY_KEY_ID` in `wrangler.jsonc`. Do not
generate or register a replacement key for this deployment.

Create a temporary Wrangler secrets bundle outside this repository from that
existing private key and the app request-proof key. The containing directory
must deny group and world access, and the JSON file mode must be exactly
`0600`; the JSON shape is exactly:

```json
{
  "ALCHEMY_JWT_PRIVATE_KEY": "<complete PKCS8 PEM, JSON-escaped>",
  "ALCHEMY_JWT_REQUEST_PROOF_KEY": "<canonical 32-byte unpadded base64url>"
}
```

Keep the same canonical proof key in a separate user-owned mode-`0600`,
non-symlink regular file inside an owner-only directory outside this
repository. Local Xcode and ASC workflows currently default to
`/Users/ivan/Developer/secrets/tools/ALCHEMY_JWT_REQUEST_PROOF_KEY`; an explicit
`ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE` may override that path for ASC. The file
may contain the 43 characters alone or one trailing LF. The key is necessarily
present in the shipped app, but the source file and Wrangler bundle must still
remain out of version control and logs.

The tracked
`Scripts/alchemy_jwt_request_proof_key.sha256` file contains the lowercase
SHA-256 digest of the canonical 43 ASCII key characters, excluding the
optional source LF. The digest is safe to commit because the key has 256 bits
of random entropy. Worker preflights, live validation, Xcode resource
bundling, and archive/export checks load this fixed fingerprint
automatically; there is no command-line or environment override. Do not edit
the fingerprint for an ordinary release. Changing it is an explicit emergency
proof-key replacement that intentionally invalidates every older app build.

Before any upload, prove that the protected private key matches the supplied
SPKI public key, and that the independently supplied app proof key exactly
matches the Worker secret:

```sh
npm run validate:keypair -- \
  --secrets-file /absolute/protected/path/alchemy-jwt-secrets.json \
  --public-key-file /absolute/protected/path/alchemy-jwt-public.pem \
  --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key \
  --expected-kid "$ALCHEMY_KEY_ID"
```

The preflight rejects final-component symlinks, non-regular inputs, unsafe
canonical ancestor chains, non-owner-only secret directories, unsafe
secrets-file permissions, inputs that change while being read, malformed
bundles, PKCS1 or encrypted private keys, non-SPKI public keys, concatenated
PEM envelopes, non-RSA-2048 keys, non-65537 exponents, mismatched keys, and a
failed in-memory sign/verify check. It also requires a canonical 32-byte proof
key and compares the decoded Worker/app key bytes in constant time. It never
prints a path, key, fingerprint, `kid`, JWT, proof, or signature. The app key
must also match the fixed tracked fingerprint before either input is accepted.

This local check cannot attest which public key is registered in the Alchemy
dashboard or prove that `ALCHEMY_KEY_ID` belongs to the supplied public key.
Confirm those values in the intended Alchemy app's Security settings. The
strict live validation below is the end-to-end proof that Alchemy accepts
the deployed private-key/`kid` combination.

For production uploads, use `npm run upload:validated` rather than invoking
`wrangler versions upload` directly. Before reading the signing bundle, the
wrapper parses the explicitly selected `wrangler.jsonc` with the pinned local
Wrangler, rejects redirected or ambiguous configuration, and requires its
root `vars.ALCHEMY_KEY_ID` to match `--expected-kid`. It then validates the
signing inputs once and copies their exact bytes to a fresh owner-only
snapshot. Immediately before upload it takes one protected snapshot of the
Worker project with stable per-file reads and a complete second source-tree
comparison, writes the exact validated configuration bytes into that snapshot,
revalidates the entire staged tree, and runs Wrangler from it. Concurrent
rewrites, swaps, additions, removals, or symbolic links fail closed; edits after
staging cannot change the configuration or source Wrangler consumes.

The child uses an explicit empty env file, the validated Worker name, the
already-verified key ID, Wrangler's top-level environment, and the production
public Cloudflare API. It requires exactly one explicit
`CLOUDFLARE_API_TOKEN`, rejects legacy or ambiguously cased Cloudflare
credentials, and receives only that token plus basic process-runtime variables
from the parent. Cached Wrangler authentication is never a fallback. In
particular, dotenv files, auth-profile locations, proxies, alternate API
targets, CI Worker-name overrides, Node injection options, and Wrangler logging
controls are not inherited. Wrangler output remains sanitized and disk logging
is disabled while the signing key is in scope. The checked-in `account_id`
therefore remains authoritative, so credentials for another account fail
closed instead of targeting a same-named Worker. Load the scoped Workers-edit
token from the protected `CLOUDFLARE_API_TOKEN_FILE` immediately before running
the wrapper; local dotenv credentials are intentionally ignored.

The wrapper removes the signing, environment, and staged-Worker snapshots after
Wrangler has fully closed on success, failure, `SIGHUP`, `SIGINT`, or
`SIGTERM`. On an interrupt it asks Wrangler to terminate with `SIGTERM`,
escalates to `SIGKILL` after a bounded grace period if necessary, waits for
child settlement, cleans up, and then re-raises the original signal for
conventional parent-process exit behavior. No process can clean up after it
receives `SIGKILL`, loses power, or is terminated by the host, so the source
bundle and temporary filesystem must retain their owner-only protections.

For a first deployment or a separately approved future signing-key rotation,
generate an RSA-2048 keypair with public exponent `65537`, keep the private key
as unencrypted PKCS8 PEM, register only the SPKI public key with Alchemy, and
record the assigned non-secret `kid`. That is not part of this rollout.

## Account-level HTTP to HTTPS redirect

The zone's Single Redirect ruleset is full. Do not add or replace a Single
Redirect. Configure a host-scoped **account-level Bulk Redirect** instead:

| Bulk Redirect field | Required value |
| --- | --- |
| Source URL | `http://api.lil.org/` |
| Target URL | `https://api.lil.org/` |
| Status | `308` |
| Subpath matching | enabled |
| Preserve path suffix | enabled |
| Preserve query string | enabled |
| Include subdomains | disabled |

Put this entry in an account-level Bulk Redirect List and enable that list with
an account-level Bulk Redirect Rule. Keeping the `http` scheme in the source
and subdomains disabled prevents the rule from affecting HTTPS traffic or
other `lil.org` hosts. The `308` preserves the HTTP method and request body.

The live validator requires this redirect to produce the exact HTTPS
`Location` and verifies that the redirect response did not reach the Worker.
Cloudflare configuration is an external rollout step; repository validation
does not create or modify the rule.

## First HMAC production rollout

Version 1 has not shipped, so the HMAC request-proof contract is the first
production client contract. There is no unsigned compatibility path for an
earlier request contract. Before the first HMAC client ships, the currently
active pre-HMAC version may be retained only as the temporary prelaunch
recovery anchor described below. After launch, do not preserve or restore it:
it is neither a valid client fallback nor an acceptable post-launch rollback
target.

Do not change the Alchemy signing private key, registered public key, or `kid`
during this rollout. The request-proof flow also has exactly one shared key:
there is no proof-key ID, previous-key slot, dual-key acceptance window, or
scheduled rotation. Changing that key would immediately break every shipped
build and is outside this procedure.

Do not bypass the validated uploader with `wrangler secret put` or a one-step
`wrangler deploy`; either can immediately activate a mismatched
code/config/secret combination.

Run these commands from this directory after `npm ci`. Every rollout Wrangler
operation below goes through `npm run rollout`. The wrapper derives the Worker
name from stable bounded reads of the exact checked-in configuration, then
runs from a protected snapshot containing those retained config bytes, the
required Worker tree, relative schema reference, and an empty env file. It
revalidates the snapshot immediately before spawn, supplies Wrangler's
top-level environment, forces the production public Cloudflare API, and strips
environment inputs that could redirect the command. It accepts no
configuration, environment, Worker-name, account-profile, or arbitrary
Wrangler flags. Every traffic mutation also reads the fixed deployment-status
endpoint immediately beforehand and aborts unless it exactly matches the
required UUID/percentage precondition supplied in the command.

1. Inspect the current deployment for audit context. Record the pre-HMAC
   version only as the temporary prelaunch recovery anchor; never treat it as a
   post-launch rollback baseline:

   ```sh
   npm run rollout -- deployments-list
   npm run rollout -- versions-list
   ```

2. Run the complete local suite and keypair preflight. Then upload the code,
   `kid`, TTL, and exact validated signing/proof secrets as one undeployed
   version:

   ```sh
   npm run upload:validated -- \
     --secrets-file /absolute/protected/path/alchemy-jwt-secrets.json \
     --public-key-file /absolute/protected/path/alchemy-jwt-public.pem \
     --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --tag "alchemy-jwt-hmac-v1-YYYYMMDD" \
     --message "Establish HMAC-gated Alchemy JWT issuance"
   ```

   The upload wrapper uses a protected, internally selected Wrangler output
   file and prints exactly one non-secret success result containing the
   canonical uploaded UUID. Record it as `HMAC_INITIAL_VERSION_ID` and confirm
   it with `npm run rollout -- versions-list`. The upload wrapper enables
   Wrangler strict mode. If it reports remote changes, stop and reconcile them
   instead of overriding them.

3. Require the currently active prelaunch version to remain the sole version
   at 100% traffic and record its UUID as `PRELAUNCH_ANCHOR_VERSION_ID`. The
   currently observed anchor is
   `c5c74433-eb49-4998-979b-e78d17da74f8`; stop if the live deployment has
   drifted. Add the HMAC candidate at 0% while retaining that anchor at 100%:

   ```sh
   npm run rollout -- deploy \
     "$PRELAUNCH_ANCHOR_VERSION_ID@100" \
     "$HMAC_INITIAL_VERSION_ID@0" \
     --require-current "$PRELAUNCH_ANCHOR_VERSION_ID@100" \
     --message "Validate initial HMAC Alchemy JWT candidate"
   ```

   This deployment also applies the checked-in non-versioned Worker settings,
   including disabled automatic tracing. Do not use the prelaunch anchor as a
   post-launch compatibility or rollback version.

   Pinned Wrangler creates the traffic deployment before it patches
   non-versioned script settings. Treat every deploy exit—success or
   failure—as potentially partial. Immediately inspect both remote states:

   ```sh
   npm run rollout -- deployments-list
   npm run rollout -- settings-check
   ```

   Require the exact anchor-at-100%/candidate-at-0% deployment and a passing
   `traces=disabled` settings result before override validation. Never retry,
   promote, or restore based only on the previous command's exit code.

4. Validate the 0%-traffic candidate through Cloudflare's supported version
   override:

   ```sh
   npm run validate:live -- \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --expected-version "$HMAC_INITIAL_VERSION_ID" \
     --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key \
     --version-override
   ```

   The validator verifies the redirect, response policy, route and
   request-proof contract—including signed stale, future, and malformed-nonce
   rejection—exact JWT `kid`, six-hour TTL, Worker version, and the complete
   configured Alchemy endpoint matrix. It probes `eth-mainnet` before starting
   the catalog; a failed canary skips the matrix. RPC retries are bounded to
   three attempts by default (maximum five) and apply only to network failures,
   timeouts, HTTP `408`, `425`, `429`, and `5xx`.

5. Promote only the validated candidate, then repeat the complete live
   validation through the ordinary public route:

   ```sh
   npm run rollout -- deploy \
     "$HMAC_INITIAL_VERSION_ID@100" \
     --require-current "$PRELAUNCH_ANCHOR_VERSION_ID@100" \
     "$HMAC_INITIAL_VERSION_ID@0" \
     --message "Activate validated initial HMAC Alchemy JWT contract"

   npm run validate:live -- \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --expected-version "$HMAC_INITIAL_VERSION_ID" \
     --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key

   npm run rollout -- deployments-list
   npm run rollout -- settings-check
   ```

   Require the candidate to be the sole 100% version and the settings check to
   pass before release verification.

6. Run the narrow release verifier with one API-token auth mode:

   ```sh
   npm run verify:release -- \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --expected-version "$HMAC_INITIAL_VERSION_ID" \
     --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key
   ```

   `CLOUDFLARE_API_TOKEN` must contain the scoped token. Legacy API-key,
   account-email, and service-key auth variables are rejected. This command can
   only run pinned `wrangler deployments status --json`, perform a fixed
   read-only Cloudflare API GET for this checked-in account and Worker, and
   validate the fixed public issuer plus `eth-mainnet` canary. It requires the
   expected UUID to be the only version at 100%, automatic traces to be
   disabled remotely, and the intended logs policy. It exposes no upload,
   deploy, secret, rollback, routing override, Worker-name, account, or catalog
   option.

7. Record `HMAC_INITIAL_VERSION_ID` as `HMAC_BASELINE_VERSION_ID`. Only after
   steps 1–6 pass, archive and export all production app products
   with the same protected `ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE`. Run the
   archive/export artifact validation before publishing. Do not archive,
   publish, or submit any app if Worker validation or artifact validation
   fails.

If candidate validation fails before promotion, first inspect both deployment
status and script settings, then keep or restore the prelaunch anchor at 100%
from the observed state, correct the candidate, and retry. If promotion or
post-promotion validation fails while apps remain unreleased, inspect both
remote states before deciding whether restoration is needed; restore the
prelaunch anchor when necessary and keep release verification blocked. After
every restoration attempt, inspect both states again. Once any HMAC client
ships, the pre-HMAC anchor must never be restored; failures are then fix-forward
or roll back only to a previously validated HMAC-compatible baseline. Delete
the temporary Wrangler secrets bundle only after Worker and artifact validation
complete; retain the separately protected source keys and the recorded HMAC
baseline.

## Future HMAC-compatible Worker updates

Future updates may use a 0%-traffic candidate only after the recorded baseline
is active. Upload the candidate with the same request-proof key bytes and
contract, then create a deployment containing the baseline at 100% and the
candidate at 0%:

```sh
npm run rollout -- deploy \
  "$HMAC_BASELINE_VERSION_ID@100" \
  "$HMAC_CANDIDATE_VERSION_ID@0" \
  --require-current "$HMAC_BASELINE_VERSION_ID@100" \
  --message "Smoke test HMAC-compatible Alchemy JWT candidate"
```

Validate the candidate with `--version-override`, its exact version UUID, and
the protected app proof-key file before promotion. Cloudflare applies an
override only when the requested version is in the current deployment; see
[Cloudflare's version override documentation](https://developers.cloudflare.com/workers/versions-and-deployments/version-overrides/).

```sh
npm run validate:live -- \
  --expected-kid "$ALCHEMY_KEY_ID" \
  --expected-version "$HMAC_CANDIDATE_VERSION_ID" \
  --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key \
  --version-override
```

If validation passes, promote the candidate and validate the exact public
version again without an override:

```sh
npm run rollout -- deploy \
  "$HMAC_CANDIDATE_VERSION_ID@100" \
  --require-current "$HMAC_BASELINE_VERSION_ID@100" \
  "$HMAC_CANDIDATE_VERSION_ID@0" \
  --message "Promote validated HMAC-compatible Alchemy JWT version"

npm run validate:live -- \
  --expected-kid "$ALCHEMY_KEY_ID" \
  --expected-version "$HMAC_CANDIDATE_VERSION_ID" \
  --app-proof-key-file /absolute/protected/path/alchemy-jwt-request-proof.key
```

If pre-promotion validation fails, leave the baseline at 100% and fix the
candidate. If a post-promotion check fails, rollback is allowed only to a
previously live-validated HMAC-compatible version that uses the same proof-key
contract and key bytes:

```sh
npm run rollout -- deploy \
  "$HMAC_BASELINE_VERSION_ID@100" \
  --require-current "$HMAC_CANDIDATE_VERSION_ID@100" \
  --message "Restore validated HMAC-compatible Alchemy JWT baseline"
```

Re-run strict live validation against the restored version. Never waive the
version header, request-proof, TTL, or endpoint-matrix checks for a rollback.
After a future candidate has passed an observation period, it may become the
recorded baseline for the next update.

This rollout does not add or retire any Alchemy public signing key. For a
separately approved future RSA signing-key rotation, keep the previous public
key registered because existing JWTs remain valid for the full six-hour
lifetime. Wait at least `21600 + 300` seconds after the last possible issuance
from the previous signing version before removing that public key, and retain a
validated HMAC-compatible Worker version for rollback through that window and
the operational observation period.

Repository rollout commands do not revoke, delete, or replace external Alchemy
credentials or dashboard configuration. Any such action requires a separate,
explicitly approved manual procedure; do not automate it as part of Worker or
app publication.

## Logging and incident behavior

The Worker never logs request bodies, request-proof or authorization headers,
JWTs, signing material, or the Alchemy `kid`. Expected client errors are not
logged. Internal failures emit only a stable structured category and fail
closed with a generic response. Cloudflare invocation logs and automatic
traces are disabled; observability retains only the Worker's explicitly
emitted redacted logs.
