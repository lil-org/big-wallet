#!/usr/bin/env bash
set -euo pipefail

tests_directory="$(cd "$(dirname "$0")" && pwd)"
repository_directory="$(cd "$tests_directory/../.." && pwd)"
common_script="$repository_directory/Scripts/asc/common.sh"
publish_script="$repository_directory/Scripts/asc/publish.sh"
publish_check_script="$repository_directory/Scripts/asc/publish_check.sh"
submit_script="$repository_directory/Scripts/asc/submit_review.sh"
toolchain_script="$repository_directory/Scripts/inpage_provider_toolchain.sh"
workflow_file="$repository_directory/.asc/workflow.json"

test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/asc-alchemy-release-guard.XXXXXX")"
test_root="$(cd "$test_root" && pwd -P)"
logs_directory="$test_root/logs"
mkdir -p "$logs_directory"
trap '/bin/rm -rf "$test_root"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  local name="$1"
  shift
  local stdout_file="$logs_directory/$name.stdout"
  local stderr_file="$logs_directory/$name.stderr"

  set +e
  ( "$@" ) >"$stdout_file" 2>"$stderr_file"
  local status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "$name unexpectedly succeeded"
  [[ ! -s "$stdout_file" ]] || fail "$name wrote to stdout"
  [[ -s "$stderr_file" ]] || fail "$name did not report an error"
}

source "$common_script"

preferred_tool_directory="$test_root/preferred tools"
mkdir -p "$preferred_tool_directory"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$preferred_tool_directory/node"
chmod 700 "$preferred_tool_directory/node"
(
  source "$toolchain_script"
  HOME="$test_root/empty home"
  PATH="$preferred_tool_directory:/usr/bin:/bin"
  inpage_provider_prepare_tool_path
  [[ "$(command -v node)" == "$preferred_tool_directory/node" ]]
) || fail "tool discovery replaced the caller-selected pinned runtime"

tracked_kid="$(jq -r '.env.ALCHEMY_JWT_EXPECTED_KID // empty' "$workflow_file")"
tracked_worker_version="$(jq -r '.env.ALCHEMY_JWT_EXPECTED_WORKER_VERSION // empty' "$workflow_file")"
[[ "$tracked_kid" == "3548436c-9bdb-4f3a-b1e8-ff9d01450110" ]] \
  || fail "the tracked Alchemy JWT kid is missing or incorrect"
[[ "$tracked_worker_version" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail "the tracked Alchemy Worker version is not a canonical UUID"

if [[ "$tracked_worker_version" == "$ALCHEMY_JWT_PRELAUNCH_ANCHOR_VERSION" ]]; then
  expect_failure prelaunch-anchor-pin load_alchemy_release_pins
else
  load_alchemy_release_pins
  [[ "$ALCHEMY_JWT_EXPECTED_WORKER_VERSION" == "$tracked_worker_version" ]] \
    || fail "the promoted Worker version was not loaded from the tracked workflow"
fi

receipt_runtime="$test_root/receipt runtime"
ASC_REPORTS_DIR="$receipt_runtime/reports"
ALCHEMY_JWT_RECEIPTS_DIR="$ASC_REPORTS_DIR/validated-builds"
artifact="$test_root/Big Wallet release.ipa"
printf '%s' "synthetic release artifact" >"$artifact"
proof_fingerprint="$(printf '%064d' 0)"

write_valid_receipt() {
  local validated_artifact_sha256
  validated_artifact_sha256="$(release_artifact_sha256 "$artifact")"
  write_alchemy_release_receipt \
    IOS \
    1.2.3 \
    42 \
    synthetic-build-id \
    "$artifact" \
    "$proof_fingerprint" \
    "$validated_artifact_sha256"
}

write_valid_receipt
receipt="$(alchemy_release_receipt_path IOS)"
[[ -f "$receipt" && "$(/usr/bin/stat -f '%Lp' "$receipt")" == "600" ]] \
  || fail "the release receipt was not written atomically with mode 0600"
jq -e '
  keys == [
    "artifactPath",
    "artifactSHA256",
    "buildId",
    "buildNumber",
    "platform",
    "proofKeyFingerprint",
    "schemaVersion",
    "version"
  ]
' "$receipt" >/dev/null \
  || fail "the release receipt contains unexpected fields"

load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"
[[ "$ALCHEMY_RELEASE_RECEIPT_BUILD_ID" == "synthetic-build-id" ]] \
  || fail "the validated receipt did not return its build id"
[[ "$ALCHEMY_RELEASE_RECEIPT_ARTIFACT_PATH" == "$artifact" ]] \
  || fail "the validated receipt did not return its canonical artifact"

preupload_artifact_sha256="$(release_artifact_sha256 "$artifact")"
printf '%s' "changed during upload" >>"$artifact"
expect_failure receipt-write-after-artifact-change \
  write_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$artifact" \
  "$proof_fingerprint" \
  "$preupload_artifact_sha256"
printf '%s' "synthetic release artifact" >"$artifact"

expect_failure receipt-version-mismatch \
  load_and_validate_alchemy_release_receipt \
  IOS \
  9.9.9 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"
expect_failure receipt-build-number-mismatch \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  43 \
  synthetic-build-id \
  "$proof_fingerprint"
expect_failure receipt-build-id-mismatch \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  different-build-id \
  "$proof_fingerprint"
expect_failure receipt-proof-fingerprint-mismatch \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$(printf '%064d' 1)"

printf '%s' "changed after upload" >>"$artifact"
expect_failure receipt-artifact-digest-mismatch \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"
printf '%s' "synthetic release artifact" >"$artifact"
write_valid_receipt

temporary_receipt="$receipt.tmp"
jq '.unexpected = true' "$receipt" >"$temporary_receipt"
chmod 600 "$temporary_receipt"
mv "$temporary_receipt" "$receipt"
expect_failure receipt-extra-field \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"

write_valid_receipt
chmod 644 "$receipt"
expect_failure receipt-unsafe-mode \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"

chmod 600 "$receipt"
rm "$receipt"
expect_failure receipt-missing \
  load_and_validate_alchemy_release_receipt \
  IOS \
  1.2.3 \
  42 \
  synthetic-build-id \
  "$proof_fingerprint"

token_directory="$test_root/token directory"
token_file="$token_directory/cloudflare token"
mkdir "$token_directory"
chmod 700 "$token_directory"
printf '%040d' 0 >"$token_file"
chmod 600 "$token_file"
CLOUDFLARE_API_TOKEN_FILE="$token_file"
load_cloudflare_api_token_file
[[ "${#CLOUDFLARE_API_TOKEN_VALUE}" -eq 40 ]] \
  || fail "a valid Cloudflare token file was not loaded"
if /usr/bin/env | grep -F "$CLOUDFLARE_API_TOKEN_VALUE" >/dev/null; then
  fail "the loaded Cloudflare API token was exported to unrelated child processes"
fi
unset CLOUDFLARE_API_TOKEN_VALUE

expect_failure raw-cloudflare-token-environment /usr/bin/env \
  CLOUDFLARE_API_TOKEN=synthetic-raw-token-value \
  CLOUDFLARE_API_TOKEN_FILE="$token_file" \
  bash -c "source '$common_script'; load_cloudflare_api_token_file"

chmod 644 "$token_file"
expect_failure cloudflare-token-unsafe-mode bash -c \
  "source '$common_script'; CLOUDFLARE_API_TOKEN_FILE='$token_file'; load_cloudflare_api_token_file"
chmod 600 "$token_file"

awk '
  index($0, "Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh") {
    artifact_validator_line = NR
  }
  index($0, "run_alchemy_worker_release_verification \"$proof_key_file\"") {
    verifier_line = NR
  }
  index($0, "upload_attempted=true") {
    upload_attempted_line = NR
  }
  index($0, "upload_json=\"$(asc builds upload") {
    upload_line = NR
  }
  index($0, "write_alchemy_release_receipt") {
    receipt_line = NR
  }
  index($0, "emit_publish_result") && NR > receipt_line {
    result_line = NR
  }
  END {
    if (artifact_validator_line == 0 ||
        artifact_validator_line <= verifier_line ||
        upload_attempted_line <= artifact_validator_line ||
        upload_line <= upload_attempted_line ||
        receipt_line <= upload_line ||
        result_line <= receipt_line) {
      exit 1
    }
  }
' "$publish_script" \
  || fail "publish does not verify the exact artifact and Worker before upload and receipt emission"

awk '
  index($0, "load_and_validate_alchemy_release_receipt") {
    receipt_line = NR
  }
  index($0, "Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh") {
    artifact_validator_line = NR
  }
  index($0, "run_alchemy_worker_release_verification \"$proof_key_file\"") {
    verifier_line = NR
  }
  index($0, "version_id=\"$(Scripts/asc/ensure_version.sh") {
    mutation_boundary_line = NR
  }
  END {
    if (receipt_line == 0 ||
        artifact_validator_line <= receipt_line ||
        verifier_line <= artifact_validator_line ||
        mutation_boundary_line <= verifier_line) {
      exit 1
    }
  }
' "$submit_script" \
  || fail "review submission is not fully gated before its mutation boundary"

grep -F "validate_alchemy_release_inputs" "$publish_check_script" >/dev/null \
  || fail "publish preflight does not validate the local Alchemy release inputs"

verifier_wrapper="$test_root/verifier-wrapper.sh"
awk '
  /^run_alchemy_worker_release_verification\(\) \{/ {
    active = 1
  }
  active {
    print
  }
  active && /^}/ {
    exit
  }
' "$common_script" >"$verifier_wrapper"
grep -F "npm run verify:release --" "$verifier_wrapper" >/dev/null \
  || fail "the ASC gate does not use the narrow Worker release verifier"
for legacy_auth_variable in \
  CLOUDFLARE_API_KEY \
  CLOUDFLARE_EMAIL \
  CLOUDFLARE_API_USER_SERVICE_KEY
do
  grep -F "$legacy_auth_variable" "$verifier_wrapper" >/dev/null \
    || fail "the ASC verifier does not clear legacy auth variable $legacy_auth_variable"
done
for required_option in \
  '--expected-kid' \
  '--expected-version' \
  '--app-proof-key-file'
do
  [[ "$(grep -F -c -- "$required_option" "$verifier_wrapper")" -eq 1 ]] \
    || fail "the ASC verifier wrapper does not pass exactly one $required_option"
done
for forbidden_term in \
  'rollout' \
  'upload:validated' \
  'wrangler deploy' \
  'wrangler secret' \
  '--version-override' \
  '--worker'
do
  if grep -F -- "$forbidden_term" "$verifier_wrapper" >/dev/null; then
    fail "the ASC verifier wrapper exposes a Worker mutation or override: $forbidden_term"
  fi
done
grep -F ") >&2" "$verifier_wrapper" >/dev/null \
  || fail "the ASC verifier wrapper can contaminate command-result stdout"

submit_fixture="$test_root/submit fixture"
mkdir -p \
  "$submit_fixture/.asc" \
  "$submit_fixture/Scripts/asc" \
  "$submit_fixture/Workers/alchemy-jwt" \
  "$submit_fixture/Wallet.xcodeproj" \
  "$submit_fixture/App iOS" \
  "$submit_fixture/App macOS" \
  "$submit_fixture/Big Wallet Ambient" \
  "$submit_fixture/Safari iOS/Resources" \
  "$submit_fixture/Safari macOS/Resources"
for relative_file in \
  Scripts/asc/common.sh \
  Scripts/asc/ensure_version.sh \
  Scripts/asc/submit_review.sh \
  Scripts/validate_alchemy_jwt_request_proof_key_file.sh \
  Scripts/alchemy_jwt_request_proof_key_common.sh \
  Scripts/assert_no_bundled_alchemy_key.sh \
  Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh \
  Wallet.xcodeproj/project.pbxproj \
  "App iOS/Info.plist" \
  "App macOS/Info.plist" \
  "Big Wallet Ambient/Info.plist" \
  "Safari iOS/Resources/manifest.json" \
  "Safari macOS/Resources/manifest.json"
do
  cp -p "$repository_directory/$relative_file" "$submit_fixture/$relative_file"
done

fixture_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
fixture_key_directory="$test_root/fixture keys"
fixture_key_file="$fixture_key_directory/request proof key"
mkdir "$fixture_key_directory"
chmod 700 "$fixture_key_directory"
printf '%s' "$fixture_key" >"$fixture_key_file"
chmod 600 "$fixture_key_file"
fixture_fingerprint="$(printf '%s' "$fixture_key" | /usr/bin/shasum -a 256)"
fixture_fingerprint="${fixture_fingerprint%% *}"
printf '%s\n' "$fixture_fingerprint" \
  >"$submit_fixture/Scripts/alchemy_jwt_request_proof_key.sha256"
fixture_worker_version="db7cd8d3-4425-4fe7-8c81-01bf963b6067"
jq \
  --arg version "$fixture_worker_version" \
  '.env.ALCHEMY_JWT_EXPECTED_WORKER_VERSION = $version' \
  "$workflow_file" \
  >"$submit_fixture/.asc/workflow.json"
printf '%s\n' "24.18.0" \
  >"$submit_fixture/Workers/alchemy-jwt/.nvmrc"
printf '%s\n' \
  '{"private":true,"packageManager":"npm@11.16.0","scripts":{"verify:release":"node scripts/verify-release.mjs"}}' \
  >"$submit_fixture/Workers/alchemy-jwt/package.json"

mock_bin="$test_root/mock bin"
mock_asc_log="$logs_directory/missing-receipt.asc"
mkdir "$mock_bin"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >>"$MOCK_ASC_LOG"' \
  'exit 70' \
  >"$mock_bin/asc"
chmod 700 "$mock_bin/asc"

missing_receipt_stdout="$logs_directory/missing-receipt-submit.stdout"
missing_receipt_stderr="$logs_directory/missing-receipt-submit.stderr"
set +e
PATH="$mock_bin:$PATH" \
  MOCK_ASC_LOG="$mock_asc_log" \
  ASC_RUNTIME_ROOT="$test_root/missing receipt runtime" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$fixture_key_file" \
  "$submit_fixture/Scripts/asc/submit_review.sh" IOS \
  >"$missing_receipt_stdout" \
  2>"$missing_receipt_stderr"
missing_receipt_status=$?
set -e

[[ "$missing_receipt_status" -ne 0 ]] \
  || fail "review submission without a validated receipt unexpectedly succeeded"
[[ ! -s "$missing_receipt_stdout" ]] \
  || fail "missing-receipt review submission wrote to stdout"
grep -F "missing validated Alchemy release receipt" "$missing_receipt_stderr" >/dev/null \
  || fail "missing-receipt review submission did not report the receipt gate"
[[ ! -e "$mock_asc_log" ]] \
  || fail "review submission invoked asc before validating its release receipt"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" v24.18.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$mock_bin/node"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" 11.16.0' \
  '  exit 0' \
  'fi' \
  'if [ "${1:-}" = run ] && [ "${2:-}" = verify:release ]; then' \
  '  printf "%s\n" "$*" >>"$MOCK_NPM_LOG"' \
  '  exit 73' \
  'fi' \
  'exit 64' \
  >"$mock_bin/npm"
chmod 700 "$mock_bin/node" "$mock_bin/npm"

submit_artifact_source="$test_root/submit artifact source"
submit_artifact="$test_root/validated submit.ipa"
submit_app="$submit_artifact_source/Payload/Big Wallet.app"
submit_extension="$submit_app/PlugIns/Safari iOS.appex"
mkdir -p "$submit_extension"
cp "$fixture_key_file" "$submit_app/AlchemyJWTRequestProofKey"
cp "$fixture_key_file" "$submit_extension/AlchemyJWTRequestProofKey"
chmod 644 \
  "$submit_app/AlchemyJWTRequestProofKey" \
  "$submit_extension/AlchemyJWTRequestProofKey"
/usr/bin/ditto -c -k "$submit_artifact_source" "$submit_artifact"

submit_runtime="$test_root/valid submit runtime"
ASC_REPORTS_DIR="$submit_runtime/reports"
ALCHEMY_JWT_RECEIPTS_DIR="$ASC_REPORTS_DIR/validated-builds"
submit_version="$(current_local_version)"
submit_build_number="$(current_local_build_number)"
submit_artifact_sha256="$(release_artifact_sha256 "$submit_artifact")"
write_alchemy_release_receipt \
  IOS \
  "$submit_version" \
  "$submit_build_number" \
  validated-build-id \
  "$submit_artifact" \
  "$fixture_fingerprint" \
  "$submit_artifact_sha256"

submit_token_directory="$test_root/submit token directory"
submit_token_file="$submit_token_directory/cloudflare token"
mkdir "$submit_token_directory"
chmod 700 "$submit_token_directory"
printf '%040d' 0 >"$submit_token_file"
chmod 600 "$submit_token_file"

worker_failure_asc_log="$logs_directory/worker-failure-submit.asc"
worker_failure_npm_log="$logs_directory/worker-failure-submit.npm"
worker_failure_stdout="$logs_directory/worker-failure-submit.stdout"
worker_failure_stderr="$logs_directory/worker-failure-submit.stderr"
unset CLOUDFLARE_API_TOKEN
set +e
PATH="$mock_bin:$PATH" \
  MOCK_ASC_LOG="$worker_failure_asc_log" \
  MOCK_NPM_LOG="$worker_failure_npm_log" \
  ASC_RUNTIME_ROOT="$submit_runtime" \
  CLOUDFLARE_API_TOKEN_FILE="$submit_token_file" \
  ALCHEMY_JWT_EXPECTED_KID="$tracked_kid" \
  ALCHEMY_JWT_EXPECTED_WORKER_VERSION="$fixture_worker_version" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$fixture_key_file" \
  "$submit_fixture/Scripts/asc/submit_review.sh" \
    IOS \
    validated-build-id \
  >"$worker_failure_stdout" \
  2>"$worker_failure_stderr"
worker_failure_status=$?
set -e

[[ "$worker_failure_status" -ne 0 ]] \
  || fail "review submission ignored a failed Worker verifier"
[[ ! -s "$worker_failure_stdout" ]] \
  || fail "failed Worker verification contaminated review-submission stdout"
grep -F "run verify:release --" "$worker_failure_npm_log" >/dev/null \
  || fail "review submission did not exercise the narrow Worker verifier"
grep -F "deployed Alchemy HMAC Worker failed release verification" \
  "$worker_failure_stderr" >/dev/null \
  || fail "review submission did not report the failed Worker gate"
[[ ! -e "$worker_failure_asc_log" ]] \
  || fail "review submission invoked asc after its Worker verifier failed"

if grep -F "$fixture_key" "$logs_directory"/*.stdout "$logs_directory"/*.stderr >/dev/null 2>&1; then
  fail "a synthetic release secret leaked into test output"
fi

printf '%s\n' "ASC Alchemy release guard regression tests: PASS"
