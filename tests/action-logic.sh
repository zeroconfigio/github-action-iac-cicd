#!/usr/bin/env bash
# Duplicates action.yml's bash logic since `${{ }}` expressions need a runner; keep in sync.
set -uo pipefail

failures=0

# Mirrors action.yml's "Resolve command and state key" step, including its
# invalid-override validation, not just the default-resolution branch.
resolve_command() {
  local event_name="$1"
  local cmd="$2"

  if [ -z "$cmd" ]; then
    if [ "$event_name" = "push" ]; then
      cmd="apply"
    else
      cmd="plan"
    fi
  fi

  if [ "$cmd" != "plan" ] && [ "$cmd" != "apply" ]; then
    echo "::error::command must be 'plan' or 'apply', got '$cmd'" >&2
    return 1
  fi

  echo "$cmd"
}

# Each call passes fresh explicit args, so no scenario depends on another.
assert_resolve_command() {
  local description="$1"
  local event_name="$2"
  local command_override="$3"
  local expected="$4"

  local actual
  actual="$(resolve_command "$event_name" "$command_override")"

  if [ "$actual" = "$expected" ]; then
    echo "PASS: $description"
  else
    echo "FAIL: $description (expected '$expected', got '$actual')"
    failures=$((failures + 1))
  fi
}

assert_resolve_command \
  "pull_request with no override resolves to plan" \
  "pull_request" "" "plan"

assert_resolve_command \
  "schedule with no override resolves to plan" \
  "schedule" "" "plan"

assert_resolve_command \
  "push with no override resolves to apply" \
  "push" "" "apply"

assert_resolve_command \
  "pull_request with apply override resolves to apply" \
  "pull_request" "apply" "apply"

assert_resolve_command \
  "push with plan override resolves to plan" \
  "push" "plan" "plan"

# assert_resolve_command only checks the success path; this checks failure.
assert_resolve_command_fails() {
  local description="$1"
  local event_name="$2"
  local command_override="$3"

  if resolve_command "$event_name" "$command_override" > /dev/null 2>&1; then
    echo "FAIL: $description (expected resolve_command to fail, it succeeded)"
    failures=$((failures + 1))
  else
    echo "PASS: $description"
  fi
}

assert_resolve_command_fails \
  "an invalid command override is rejected" \
  "pull_request" "destroy"

# Mirrors the "Validate inputs and resolve backend" step's r2/s3 endpoint/region resolution.
resolve_backend() {
  local backend="$1"
  local account_id="$2"
  local endpoint="$3"
  local region="$4"

  case "$backend" in
    r2|s3) ;;
    *)
      echo "::error::backend must be 'r2' or 's3', got '$backend'" >&2
      return 1
      ;;
  esac

  if [ "$backend" = "r2" ]; then
    if [ -z "$endpoint" ]; then
      if [ -z "$account_id" ]; then
        echo "::error::account-id is required when backend is 'r2', unless endpoint is set explicitly" >&2
        return 1
      fi
      endpoint="https://$account_id.r2.cloudflarestorage.com"
    fi
    [ -n "$region" ] || region="auto"
    echo "endpoint=$endpoint region=$region use_path_style=true skip_checks=true encrypt=false"
  else
    if [ -z "$region" ]; then
      echo "::error::region is required when backend is 's3'" >&2
      return 1
    fi
    echo "endpoint=$endpoint region=$region use_path_style=false skip_checks=false encrypt=true"
  fi
}

assert_backend_resolves() {
  local description="$1"
  local backend="$2"
  local account_id="$3"
  local endpoint="$4"
  local region="$5"
  local expected_field="$6"

  local actual
  actual="$(resolve_backend "$backend" "$account_id" "$endpoint" "$region")"

  if [[ "$actual" == *"$expected_field"* ]]; then
    echo "PASS: $description"
  else
    echo "FAIL: $description (expected to contain '$expected_field', got '$actual')"
    failures=$((failures + 1))
  fi
}

assert_backend_fails() {
  local description="$1"
  local backend="$2"
  local account_id="$3"
  local endpoint="$4"
  local region="$5"

  if resolve_backend "$backend" "$account_id" "$endpoint" "$region" > /dev/null 2>&1; then
    echo "FAIL: $description (expected resolve_backend to fail, it succeeded)"
    failures=$((failures + 1))
  else
    echo "PASS: $description"
  fi
}

assert_backend_resolves \
  "r2 with account-id derives the r2 endpoint" \
  "r2" "my-account" "" "" \
  "endpoint=https://my-account.r2.cloudflarestorage.com"

assert_backend_resolves \
  "r2 with an explicit endpoint override skips account-id" \
  "r2" "" "https://custom.example.com" "" \
  "endpoint=https://custom.example.com"

assert_backend_fails \
  "r2 with neither account-id nor endpoint fails" \
  "r2" "" "" ""

assert_backend_resolves \
  "r2 with no region defaults to auto" \
  "r2" "my-account" "" "" \
  "region=auto"

assert_backend_resolves \
  "r2 sets use_path_style=true, skip_checks=true, encrypt=false" \
  "r2" "my-account" "" "" \
  "use_path_style=true skip_checks=true encrypt=false"

assert_backend_resolves \
  "s3 with a region resolves without deriving an endpoint" \
  "s3" "" "" "us-east-1" \
  "endpoint= region=us-east-1"

assert_backend_fails \
  "s3 with no region fails" \
  "s3" "" "" ""

assert_backend_resolves \
  "s3 sets use_path_style=false, skip_checks=false, encrypt=true" \
  "s3" "" "" "us-east-1" \
  "use_path_style=false skip_checks=false encrypt=true"

assert_backend_fails \
  "an invalid backend is rejected" \
  "gcs" "" "" "us-east-1"

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi

echo "All scenarios passed"
exit 0
