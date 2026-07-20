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
is rejected before request parsing or rate limiting. The account-level HTTPS
redirect described below should normally handle cleartext traffic first.

## HTTP contract

The only accepted request is:

```http
POST /v1/alchemy/jwt
Content-Type: application/json

{"installationId":"8e3100fc-1879-4b35-ae97-419d3511a289"}
```

The UUID must use lowercase canonical `8-4-4-4-12` formatting. The complete
request body is capped at 1 KiB and must contain exactly that one property.
The public UUID remains a rate-limit key, not authentication.

Successful responses retain the original contract:

```json
{
  "token": "<jwt>",
  "issuedAt": 1800000000,
  "expiresAt": 1800086400
}
```

Production uses a 24-hour (`86400` second) lifetime. The JWT header contains
only `alg`, `typ`, and Alchemy's `kid`; its payload contains only `iat` and
`exp`. Both the Worker and live validator fail closed on any other configured
or issued lifetime.

Every JSON response uses:

- `Cache-Control: no-store`
- `Content-Type: application/json; charset=utf-8`
- `Strict-Transport-Security: max-age=31536000`
- `X-Content-Type-Options: nosniff`
- `X-Alchemy-JWT-Worker-Version: <Cloudflare version UUID>`

The Worker intentionally emits no CORS headers. Version metadata is validated
before issuance or rate limiting. Missing or malformed metadata fails closed
with a generic `500` and omits the untrustworthy version header.

`JWT_ISSUANCE_RATE_LIMITER` continues to limit each canonical installation
UUID to 10 requests per 60 seconds under namespace `6478607925`. Cloudflare's
rate limiter is local to each point of presence and eventually consistent; it
is capacity protection, not a proof of client identity.

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
including the required secret, rate limiter, and version metadata binding. Do
not hand-edit that file.

Worker tests generate ephemeral RSA keys inside the local Workers runtime.
Tool tests use only ephemeral keys and local fake HTTP responses. No production
secret is required for either suite.

## Existing signing-key bundle and preflight

This remediation rollout does **not** rotate the Alchemy signing key. Reuse the
existing unencrypted RSA-2048 PKCS8 private key, its matching registered SPKI
public key, and the existing `ALCHEMY_KEY_ID` in `wrangler.jsonc`. Do not
generate or register a replacement key for this deployment.

Create a temporary Wrangler secrets bundle outside this repository from that
existing private key. The containing directory and JSON file must deny group
and world access; the JSON shape is exactly:

```json
{
  "ALCHEMY_JWT_PRIVATE_KEY": "<complete PKCS8 PEM, JSON-escaped>"
}
```

Before any upload, prove that the protected private key matches the supplied
SPKI public key and that both satisfy the local key invariants:

```sh
npm run validate:keypair -- \
  --secrets-file /absolute/protected/path/alchemy-jwt-secrets.json \
  --public-key-file /absolute/protected/path/alchemy-jwt-public.pem \
  --expected-kid "$ALCHEMY_KEY_ID"
```

The preflight rejects final-component symlinks, non-regular inputs, unsafe
canonical ancestor chains, non-owner-only secret directories, unsafe
secrets-file permissions, inputs that change while being read, malformed
bundles, PKCS1 or encrypted private keys, non-SPKI public keys, concatenated
PEM envelopes, non-RSA-2048 keys, non-65537 exponents, mismatched keys, and a
failed in-memory sign/verify check. It never prints a path, key, `kid`, JWT, or
signature.

This local check cannot attest which public key is registered in the Alchemy
dashboard or prove that `ALCHEMY_KEY_ID` belongs to the supplied public key.
Confirm those values in the intended Alchemy app's Security settings. The
zero-traffic live validation below is the end-to-end proof that Alchemy accepts
the deployed private-key/`kid` combination.

For production uploads, use `npm run upload:validated` rather than invoking
`wrangler versions upload` directly. Before reading the signing bundle, the
wrapper parses the explicitly selected `wrangler.jsonc` with the pinned local
Wrangler, rejects redirected or ambiguous configuration, and requires its
root `vars.ALCHEMY_KEY_ID` to match `--expected-kid`. It then validates the
signing inputs once and copies their exact bytes to a fresh owner-only
snapshot. Immediately before upload it takes one protected snapshot of the
Worker project, writes the exact validated configuration bytes into that
snapshot, revalidates the staged configuration, and runs Wrangler from the
staged tree. Edits to the working tree after staging therefore cannot change
the configuration or source Wrangler consumes.

The child uses an explicit empty env file, the validated Worker name, the
already-verified key ID, Wrangler's top-level environment, and the production
public Cloudflare API. It receives only Cloudflare authentication, auth-profile
locations, and basic process-runtime variables from the parent. In particular,
dotenv files, proxies, alternate API targets, CI Worker-name overrides, Node
injection options, and Wrangler logging controls are not inherited. Wrangler
output remains sanitized and disk logging is disabled while the signing key is
in scope. The checked-in `account_id` therefore remains authoritative, so
credentials for another account fail closed instead of targeting a same-named
Worker. Export `CLOUDFLARE_API_TOKEN` explicitly or authenticate Wrangler
before running the wrapper; local dotenv credentials are intentionally ignored.

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

## Zero-traffic version rollout

Do not change the signing private key, registered public key, or `kid` during
this remediation. Use Workers Versions and Deployments so the code/config
version can be tested at 0% public traffic. For any future intentional
rotation, never use `wrangler secret put` or a one-step `wrangler deploy`;
either can immediately activate a mismatched code/config/secret combination.
Run these commands from this directory after `npm ci`. Every rollout Wrangler
operation below goes through `npm run rollout`. The wrapper derives the Worker
name from stable bounded reads of the exact checked-in configuration, then
runs from a protected snapshot containing those retained config bytes, the
required Worker tree, relative schema reference, and an empty env file. It
revalidates the snapshot immediately before spawn, supplies Wrangler's
top-level environment, forces the production public Cloudflare API, and strips
environment inputs that could redirect the command. It accepts no
configuration, environment, Worker-name, account-profile, or arbitrary
Wrangler flags.

1. Inspect and record the current active version:

   ```sh
   npm run rollout -- deployments-list
   npm run rollout -- versions-list
   ```

2. Run the complete local suite and keypair preflight. Then upload the code,
   `kid`, TTL, and the exact validated private key as one undeployed version:

   ```sh
   npm run upload:validated -- \
     --secrets-file /absolute/protected/path/alchemy-jwt-secrets.json \
     --public-key-file /absolute/protected/path/alchemy-jwt-public.pem \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --tag "alchemy-jwt-remediation-YYYYMMDD" \
     --message "Enforce Alchemy JWT runtime invariants"
   ```

   Record the exact new version UUID from the output and confirm it with
   the `versions-list` wrapper command from step 1. The upload wrapper enables
   Wrangler strict mode. If it reports remote changes, stop and reconcile them
   instead of overriding them.

3. Add the new version to the deployment at 0% while the old version remains
   at 100%:

   ```sh
   npm run rollout -- deploy \
     "$OLD_VERSION_ID@100" \
     "$NEW_VERSION_ID@0" \
     --message "Smoke test Alchemy JWT remediation at zero traffic"
   ```

4. Validate the exact 0%-traffic version with a Cloudflare version override:

   ```sh
   npm run validate:live -- \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --expected-version "$NEW_VERSION_ID" \
     --version-override
   ```

   The validator polls with non-issuing `GET` requests for up to 30 seconds
   until the exact version is globally visible. It then verifies the redirect,
   response policy, route contract, exact JWT `kid`, 24-hour TTL, and Worker
   version before using the JWT.

5. The RPC phase probes `eth-mainnet` as a canary before starting the complete
   catalog. If the canary fails, the matrix is skipped. RPC retries are bounded
   to three attempts by default (maximum five) and use exponential jitter.
   A valid `Retry-After` is honored as the minimum wait, with the final delay
   always clamped to four seconds. Only network failures, timeouts, HTTP `408`,
   `425`, `429`, and `5xx` are retried. Authentication failures, other `4xx`,
   oversized or malformed responses, JSON-RPC errors, and invalid EVM/Solana
   results fail deterministically without retry.

6. If zero-traffic validation succeeds, promote the new version:

   ```sh
   npm run rollout -- deploy \
     "$NEW_VERSION_ID@100" \
     --message "Promote validated Alchemy JWT remediation"
   ```

7. Validate the public deployment without an override:

   ```sh
   npm run validate:live -- \
     --expected-kid "$ALCHEMY_KEY_ID" \
     --expected-version "$NEW_VERSION_ID"
   ```

8. Re-run the two rollout list commands from step 1 and confirm that the new
   version has 100% traffic, then delete the temporary secrets bundle. Keep the
   separately stored source key; this cleanup removes only the short-lived
   upload bundle.

If any pre-promotion check fails, leave the old version at 100% and investigate.
If a post-promotion check fails, restore the recorded old version to 100% with
the same pinned target:

```sh
npm run rollout -- deploy \
  "$OLD_VERSION_ID@100" \
  --message "Roll back failed Alchemy JWT remediation"
```

For a rollback target that already has version metadata, re-run validation
against its exact expected `kid` and version. The initial rollback target
predates `X-Alchemy-JWT-Worker-Version`, so the strict validator cannot validate
it. For that one legacy rollback only, confirm through Wrangler's deployment
state that the recorded old version has 100% traffic, then run a secret-safe
broker issuance canary and a direct `eth-mainnet` JSON-RPC canary with the
returned JWT. Do not print the JWT. A missing version header is acceptable only
for this recorded pre-metadata version; never use the legacy procedure to
validate a newly uploaded version. The validator reports only non-sensitive
host/status classifications and never prints the JWT or `kid`.

This no-rotation rollout does not add or retire any Alchemy public signing key.
For a separately approved future rotation, keep the previous public key
registered because existing JWTs remain valid for the full 24-hour lifetime.
Wait at least `86400 + 300` seconds after the last possible issuance from the
old version before removing that key, and retain the old Worker version for
rollback through that window and the operational observation period.

## Legacy embedded API key and old clients

Signing-key rotation and removal of the legacy embedded Alchemy API key are
separate decisions.

Do not revoke the legacy API key merely because the JWT-capable release passes
validation. Any installed pre-JWT wallet version still depends on that key and
will lose RPC access immediately if it is revoked. Remove it only when an
enforced minimum-version/support policy guarantees those clients are no longer
supported. If old versions remain supported indefinitely, retain the legacy
key indefinitely; telemetry can inform the decision but is not proof that no
old client remains.

JWT-capable releases must not add a fallback to the embedded legacy key. In an
emergency, revoking the legacy key is an explicit decision to break old
clients, and that user impact must be accepted before the change.

## Logging and incident behavior

The Worker never logs request bodies, authorization headers, JWTs, signing
material, or the Alchemy `kid`. Expected client errors are not logged. Internal
failures emit only a stable structured category and fail closed with a generic
response. Cloudflare invocation logs are disabled; observability retains only
the Worker's explicitly emitted redacted logs and sampled traces.
