#!/usr/bin/env bash
# Duplicates action.yml's bash logic since `${{ }}` expressions need a runner; keep in sync.
set -uo pipefail

failures=0

# Mirrors action.yml's "Resolve command and state key" step.
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

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi

echo "All scenarios passed"
exit 0
