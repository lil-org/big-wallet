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

asc_entrypoint_count=0
for asc_entrypoint in "$repository_directory"/Scripts/asc/*.sh; do
  [[ "${asc_entrypoint##*/}" != "common.sh" ]] || continue
  asc_entrypoint_count=$((asc_entrypoint_count + 1))
  awk '
    index($0, "set +x") && xtrace_line == 0 {
      xtrace_line = NR
    }
    index($0, "set +a") && allexport_line == 0 {
      allexport_line = NR
    }
    index($0, "source \"$" "_asc_entrypoint_directory/common.sh\"") {
      source_line = NR
    }
    index($0, "$(") && source_line == 0 {
      early_subprocess = 1
    }
    (index($0, "`") ||
     index($0, "<(") ||
     index($0, ">(")) && source_line == 0 {
      early_subprocess = 1
    }
    END {
      if (xtrace_line == 0 ||
          allexport_line == 0 ||
          source_line == 0 ||
          xtrace_line >= source_line ||
          allexport_line >= source_line ||
          early_subprocess) {
        exit 1
      }
    }
  ' "$asc_entrypoint" \
    || fail "${asc_entrypoint##*/} does not use the child-free credential bootstrap"
done
[[ "$asc_entrypoint_count" -eq 13 ]] \
  || fail "expected exactly 13 ASC entrypoints to use the credential bootstrap"
unset asc_entrypoint_count

bootstrap_mock_bin="$test_root/bootstrap mock bin"
bootstrap_environment_log="$logs_directory/bootstrap-child.env"
bootstrap_trace_log="$logs_directory/bootstrap-xtrace.stderr"
bootstrap_proof_secret=ASC_BOOTSTRAP_PROOF_SECRET_MUST_NOT_LEAK
bootstrap_cloudflare_secret=ASC_BOOTSTRAP_CLOUDFLARE_SECRET_MUST_NOT_LEAK
mkdir -p "$bootstrap_mock_bin"
printf '%s\n' \
  '#!/bin/sh' \
  '/usr/bin/env > "$ASC_BOOTSTRAP_ENVIRONMENT_LOG"' \
  'exec /usr/bin/dirname "$@"' \
  >"$bootstrap_mock_bin/dirname"
chmod 700 "$bootstrap_mock_bin/dirname"

set +e
/usr/bin/env \
  PATH="$bootstrap_mock_bin:$PATH" \
  ASC_BOOTSTRAP_ENVIRONMENT_LOG="$bootstrap_environment_log" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY="$bootstrap_proof_secret" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE="$bootstrap_proof_secret" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT="$bootstrap_proof_secret" \
  _alchemy_jwt_request_proof_key_captured_environment_value="$bootstrap_proof_secret" \
  _alchemy_jwt_request_proof_key_cache_valid="$bootstrap_proof_secret" \
  LOGIN_KEYCHAIN_SECRET_VALUE="$bootstrap_proof_secret" \
  login_keychain_output_with_sentinel="$bootstrap_proof_secret" \
  login_keychain_output="$bootstrap_proof_secret" \
  alchemy_key_snapshot="$bootstrap_proof_secret" \
  CLOUDFLARE_API_TOKEN="$bootstrap_cloudflare_secret" \
  CLOUDFLARE_API_TOKEN_VALUE="$bootstrap_cloudflare_secret" \
  _cloudflare_api_token_captured_environment_value="$bootstrap_cloudflare_secret" \
  _asc_cloudflare_api_token_snapshot="$bootstrap_cloudflare_secret" \
  _asc_cloudflare_api_token_selection="$bootstrap_cloudflare_secret" \
  _asc_cloudflare_api_token_cache_valid="$bootstrap_cloudflare_secret" \
  snapshot="$bootstrap_cloudflare_secret" \
  public_assignment_present="$bootstrap_cloudflare_secret" \
  SHELLOPTS=allexport:xtrace \
  /bin/bash -c "source '$common_script'" \
  >"$logs_directory/bootstrap-xtrace.stdout" \
  2>"$bootstrap_trace_log"
bootstrap_status=$?
set -e
[[ "$bootstrap_status" -eq 0 ]] \
  || fail "the ASC child-free credential bootstrap failed"
[[ -s "$bootstrap_environment_log" ]] \
  || fail "the earliest ASC dirname child was not intercepted"
for bootstrap_secret in \
  "$bootstrap_proof_secret" \
  "$bootstrap_cloudflare_secret"
do
  if grep -F "$bootstrap_secret" \
    "$bootstrap_environment_log" "$bootstrap_trace_log" >/dev/null
  then
    fail "the ASC credential bootstrap exposed a release credential"
  fi
done
unset bootstrap_secret bootstrap_status
for bootstrap_private_name in \
  ALCHEMY_JWT_REQUEST_PROOF_KEY \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
  ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT \
  _alchemy_jwt_request_proof_key_captured_environment_value \
  _alchemy_jwt_request_proof_key_cache_valid \
  LOGIN_KEYCHAIN_SECRET_VALUE \
  login_keychain_output_with_sentinel \
  login_keychain_output \
  alchemy_key_snapshot \
  CLOUDFLARE_API_TOKEN \
  CLOUDFLARE_API_TOKEN_VALUE \
  _cloudflare_api_token_captured_environment_value \
  _asc_cloudflare_api_token_snapshot \
  _asc_cloudflare_api_token_selection \
  _asc_cloudflare_api_token_cache_valid \
  snapshot \
  public_assignment_present
do
  if grep -E "^${bootstrap_private_name}=" \
    "$bootstrap_environment_log" >/dev/null
  then
    fail "$bootstrap_private_name reached the earliest ASC child"
  fi
done
unset bootstrap_private_name

preferred_tool_directory="$test_root/preferred tools"
preferred_tool_repository="$test_root/preferred tool repository"
mkdir -p "$preferred_tool_directory"
mkdir -p "$preferred_tool_repository/Workers/alchemy-jwt"
printf '%s\n' "24.18.0" \
  >"$preferred_tool_repository/Workers/alchemy-jwt/.nvmrc"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" v24.18.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$preferred_tool_directory/node"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" 11.16.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$preferred_tool_directory/npm"
chmod 700 \
  "$preferred_tool_directory/node" \
  "$preferred_tool_directory/npm"
(
  source "$toolchain_script"
  HOME="$test_root/empty home"
  HOMEBREW_PREFIX="$test_root/empty homebrew"
  PATH="$preferred_tool_directory:/usr/bin:/bin"
  inpage_provider_prepare_tool_path "$preferred_tool_repository"
  [[ "$(command -v node)" == "$preferred_tool_directory/node" ]]
) || fail "tool discovery replaced the caller-selected pinned runtime"

unpinned_tool_directory="$test_root/unpinned tools"
pinned_tool_repository="$test_root/pinned tool repository"
pinned_homebrew_prefix="$test_root/pinned homebrew"
pinned_tool_directory="$pinned_homebrew_prefix/opt/node@24/bin"
mkdir -p \
  "$unpinned_tool_directory" \
  "$pinned_tool_repository/Workers/alchemy-jwt" \
  "$pinned_tool_directory"
printf '%s\n' "24.18.0" \
  >"$pinned_tool_repository/Workers/alchemy-jwt/.nvmrc"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" v26.5.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$unpinned_tool_directory/node"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" v24.18.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$pinned_tool_directory/node"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" 11.17.0' \
  '  exit 0' \
  'fi' \
  'exit 64' \
  >"$unpinned_tool_directory/npm"
printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then' \
  '  printf "%s\n" 11.16.0' \
  '  exit 0' \
  'fi' \
  'if [ "${1:-}" = run ] && [ "${2:-}" = child-node ]; then' \
  '  node --version' \
  '  exit $?' \
  'fi' \
  'exit 64' \
  >"$pinned_tool_directory/npm"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" caller-selected-asc' \
  >"$unpinned_tool_directory/asc"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" pinned-directory-asc' \
  >"$pinned_tool_directory/asc"
chmod 700 \
  "$unpinned_tool_directory/node" \
  "$unpinned_tool_directory/npm" \
  "$unpinned_tool_directory/asc" \
  "$pinned_tool_directory/node" \
  "$pinned_tool_directory/npm" \
  "$pinned_tool_directory/asc"
(
  source "$toolchain_script"
  HOME="$test_root/empty home"
  HOMEBREW_PREFIX="$pinned_homebrew_prefix"
  PATH="$unpinned_tool_directory:/usr/bin:/bin"
  inpage_provider_prepare_tool_path "$pinned_tool_repository"
  [[ "${PATH%%:*}" == "$unpinned_tool_directory" ]]
  [[ "$(inpage_provider_run_node --version)" == "v24.18.0" ]]
  [[ "$(inpage_provider_run_npm --version)" == "11.16.0" ]]
  [[ "$(inpage_provider_run_npm run child-node)" == "v24.18.0" ]]
  [[ "$(asc)" == "caller-selected-asc" ]]
  inpage_provider_prepare_tool_path "$test_root/missing repository"
  [[ "$(inpage_provider_run_node --version)" == "v26.5.0" ]]
  [[ "$(inpage_provider_run_npm --version)" == "11.17.0" ]]
  [[ "$(asc)" == "caller-selected-asc" ]]
) || fail "tool discovery did not select the repository-pinned Homebrew runtime"

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

unset CLOUDFLARE_API_TOKEN
CLOUDFLARE_API_TOKEN="$(printf '%040d' 0)"
export CLOUDFLARE_API_TOKEN
load_cloudflare_api_token
[[ "${#CLOUDFLARE_API_TOKEN_VALUE}" -eq 40 ]] \
  || fail "a valid Cloudflare token environment value was not loaded"
if /usr/bin/env | grep -F "$CLOUDFLARE_API_TOKEN_VALUE" >/dev/null; then
  fail "the loaded Cloudflare API token was exported to unrelated child processes"
fi
[[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] \
  || fail "the source Cloudflare API token remained in the environment"
cached_cloudflare_token="$CLOUDFLARE_API_TOKEN_VALUE"
export CLOUDFLARE_API_TOKEN_VALUE
CLOUDFLARE_API_TOKEN="$(printf '%040d' 1)"
export CLOUDFLARE_API_TOKEN
load_cloudflare_api_token
[[ "$CLOUDFLARE_API_TOKEN_VALUE" == "$cached_cloudflare_token" ]] \
  || fail "the validated Cloudflare API token was not cached for the release workflow"
[[ "${CLOUDFLARE_API_TOKEN+x}" != x ]] \
  || fail "a cached Cloudflare token reload did not scrub the public token"
if /usr/bin/env | grep -E '^CLOUDFLARE_API_TOKEN_VALUE=' >/dev/null; then
  fail "a cached Cloudflare token reload retained a hostile export attribute"
fi
unset cached_cloudflare_token
unset CLOUDFLARE_API_TOKEN_VALUE

(
  CLOUDFLARE_API_TOKEN="$(printf '%040d' 1)"
  export CLOUDFLARE_API_TOKEN
  source "$common_script"
  CLOUDFLARE_API_TOKEN_VALUE="$(printf '%040d' 3)"
  export CLOUDFLARE_API_TOKEN_VALUE
  CLOUDFLARE_API_TOKEN="$(printf '%040d' 2)"
  load_cloudflare_api_token
  [[ "$CLOUDFLARE_API_TOKEN_VALUE" == "$(printf '%040d' 2)" ]]
) || fail "a post-source Cloudflare token assignment did not take precedence"

expect_failure empty-post-source-cloudflare-token /usr/bin/env \
  HOME="$test_root/no-login-keychain" \
  CLOUDFLARE_API_TOKEN="$(printf '%040d' 1)" \
  bash -c "source '$common_script'; alchemy_jwt_request_proof_key_run_keychain_supervisor() { return 1; }; CLOUDFLARE_API_TOKEN=; load_cloudflare_api_token"
grep -F "is unavailable in the environment and login Keychain" \
  "$logs_directory/empty-post-source-cloudflare-token.stderr" >/dev/null \
  || fail "an explicit empty Cloudflare token did not select Keychain"
expect_failure malformed-post-source-cloudflare-token /usr/bin/env \
  HOME="$test_root/no-login-keychain" \
  CLOUDFLARE_API_TOKEN="$(printf '%040d' 1)" \
  bash -c "source '$common_script'; CLOUDFLARE_API_TOKEN=too-short; load_cloudflare_api_token"
grep -F "must contain 20 to 512 characters" \
  "$logs_directory/malformed-post-source-cloudflare-token.stderr" >/dev/null \
  || fail "a malformed non-empty Cloudflare token did not fail validation"
expect_failure malformed-post-source-cloudflare-cache /usr/bin/env \
  bash -c "source '$common_script'; export CLOUDFLARE_API_TOKEN_VALUE=too-short _asc_cloudflare_api_token_cache_valid=1; load_cloudflare_api_token"
grep -F "must contain 20 to 512 characters" \
  "$logs_directory/malformed-post-source-cloudflare-cache.stderr" >/dev/null \
  || fail "a malformed post-source Cloudflare cache did not fail validation"
expect_failure malformed-cloudflare-token-environment /usr/bin/env \
  CLOUDFLARE_API_TOKEN=too-short \
  bash -c "source '$common_script'; load_cloudflare_api_token"
expect_failure missing-cloudflare-token-and-keychain /usr/bin/env \
  HOME="$test_root/no-login-keychain" \
  CLOUDFLARE_API_TOKEN= \
  bash -c "source '$common_script'; alchemy_jwt_request_proof_key_run_keychain_supervisor() { return 1; }; load_cloudflare_api_token"

hostile_cloudflare_export_probe="$logs_directory/hostile-cloudflare-export.env"
(
  CLOUDFLARE_API_TOKEN="$(printf '%040d' 3)"
  CLOUDFLARE_API_TOKEN_VALUE=hostile-cache
  _cloudflare_api_token_captured_environment_value=hostile-private-cache
  _asc_cloudflare_api_token_snapshot=hostile-exported-scratch
  _asc_cloudflare_api_token_selection=hostile-exported-scratch
  _asc_cloudflare_api_token_cache_valid=hostile-exported-scratch
  snapshot=hostile-exported-scratch
  public_assignment_present=hostile-exported-scratch
  export CLOUDFLARE_API_TOKEN \
    CLOUDFLARE_API_TOKEN_VALUE \
    _cloudflare_api_token_captured_environment_value \
    _asc_cloudflare_api_token_snapshot \
    _asc_cloudflare_api_token_selection \
    _asc_cloudflare_api_token_cache_valid \
    snapshot \
    public_assignment_present
  source "$common_script"
  [[ "${CLOUDFLARE_API_TOKEN+x}" != x ]] \
    || fail "the source Cloudflare token remained public"
  [[ "${CLOUDFLARE_API_TOKEN_VALUE+x}" != x ]] \
    || fail "a hostile Cloudflare cache survived source bootstrap"
  load_cloudflare_api_token
  /usr/bin/env >"$hostile_cloudflare_export_probe"
)
for hostile_cloudflare_variable in \
  CLOUDFLARE_API_TOKEN \
  CLOUDFLARE_API_TOKEN_VALUE \
  _cloudflare_api_token_captured_environment_value \
  _asc_cloudflare_api_token_snapshot \
  _asc_cloudflare_api_token_selection \
  _asc_cloudflare_api_token_cache_valid \
  snapshot \
  public_assignment_present
do
  if grep -E "^${hostile_cloudflare_variable}=" \
    "$hostile_cloudflare_export_probe" >/dev/null
  then
    fail "$hostile_cloudflare_variable retained a hostile export attribute"
  fi
done
if grep -F "$(printf '%040d' 3)" "$hostile_cloudflare_export_probe" >/dev/null; then
  fail "the loaded Cloudflare token was exported through hostile scratch state"
fi

awk '
  index($0, "Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh") {
    artifact_validator_line = NR
  }
  index($0, "run_alchemy_worker_release_verification") {
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
  index($0, "run_alchemy_worker_release_verification") {
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
grep -F "run_alchemy_release_npm run verify:release --" "$verifier_wrapper" >/dev/null \
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
  '--expected-version'
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
  "$submit_fixture/Safari Shared/Resources"
for relative_file in \
  Scripts/asc/common.sh \
  Scripts/asc/ensure_version.sh \
  Scripts/asc/submit_review.sh \
  Scripts/inpage_provider_toolchain.sh \
  Scripts/validate_alchemy_jwt_request_proof_key.sh \
  Scripts/alchemy_jwt_request_proof_key_common.sh \
  Scripts/alchemy_login_keychain_supervisor.pl \
  Scripts/assert_no_bundled_alchemy_key.sh \
  Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh \
  Wallet.xcodeproj/project.pbxproj \
  "App iOS/Info.plist" \
  "App macOS/Info.plist" \
  "Safari Shared/Resources/manifest.json"
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
  ALCHEMY_JWT_REQUEST_PROOF_KEY="$fixture_key" \
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

submit_cloudflare_token="$(printf '%040d' 0)"

worker_failure_asc_log="$logs_directory/worker-failure-submit.asc"
worker_failure_npm_log="$logs_directory/worker-failure-submit.npm"
worker_failure_stdout="$logs_directory/worker-failure-submit.stdout"
worker_failure_stderr="$logs_directory/worker-failure-submit.stderr"
set +e
PATH="$mock_bin:$PATH" \
  MOCK_ASC_LOG="$worker_failure_asc_log" \
  MOCK_NPM_LOG="$worker_failure_npm_log" \
  ASC_RUNTIME_ROOT="$submit_runtime" \
  CLOUDFLARE_API_TOKEN="$submit_cloudflare_token" \
  ALCHEMY_JWT_EXPECTED_KID="$tracked_kid" \
  ALCHEMY_JWT_EXPECTED_WORKER_VERSION="$fixture_worker_version" \
  ALCHEMY_JWT_REQUEST_PROOF_KEY="$fixture_key" \
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
