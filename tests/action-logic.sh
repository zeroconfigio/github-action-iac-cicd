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

# Mirrors action.yml's "Plan" step's plan invocation (command construction only,
# never invokes the real binary).
build_plan_command() {
  local bin="$1"
  local runner_temp="$2"
  local extra_args="$3"

  echo "$bin plan -input=false -no-color -detailed-exitcode -out=$runner_temp/iac-cicd-tfplan.bin $extra_args"
}

# Mirrors action.yml's "Plan" step's guard around the show -json call: it only
# runs when the plan's exit code is not 1 (0 = no changes, 2 = changes).
build_plan_show_command() {
  local bin="$1"
  local runner_temp="$2"
  local plan_exit_code="$3"

  if [ "$plan_exit_code" = "1" ]; then
    return 1
  fi

  echo "$bin show -json $runner_temp/iac-cicd-tfplan.bin"
}

# Mirrors action.yml's "Apply" step's own internal plan invocation (no
# -detailed-exitcode: Apply doesn't report has-changes the way Plan does).
build_apply_plan_command() {
  local bin="$1"
  local runner_temp="$2"
  local extra_args="$3"

  echo "$bin plan -out=$runner_temp/iac-cicd-tfplan.bin -input=false -no-color $extra_args"
}

# Mirrors action.yml's "Apply" step's guard around its own show -json call: it
# only runs when the internal plan's exit code is 0 (anything else fails the step).
build_apply_plan_show_command() {
  local bin="$1"
  local runner_temp="$2"
  local plan_exit_code="$3"

  if [ "$plan_exit_code" != "0" ]; then
    return 1
  fi

  echo "$bin show -json $runner_temp/iac-cicd-tfplan.bin"
}

# Mirrors action.yml's "Apply" step's final apply invocation: applies the saved
# plan file rather than an implicit bare apply with no file argument.
build_apply_command() {
  local bin="$1"
  local runner_temp="$2"

  echo "$bin apply -input=false -auto-approve $runner_temp/iac-cicd-tfplan.bin"
}

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $description"
  else
    echo "FAIL: $description (expected '$haystack' to contain '$needle')"
    failures=$((failures + 1))
  fi
}

assert_not_equal() {
  local description="$1"
  local actual="$2"
  local unexpected="$3"

  if [ "$actual" = "$unexpected" ]; then
    echo "FAIL: $description (command matched the bare form: '$actual')"
    failures=$((failures + 1))
  else
    echo "PASS: $description"
  fi
}

assert_command_fails() {
  local description="$1"
  shift

  if "$@" > /dev/null 2>&1; then
    echo "FAIL: $description (expected the command to fail, but it succeeded)"
    failures=$((failures + 1))
  else
    echo "PASS: $description"
  fi
}

# Scenario 1: Given a plan step invocation, when constructed, then the command
# includes -out= pointing at $RUNNER_TEMP.
plan_cmd="$(build_plan_command "tofu" "/tmp/runner-temp" "")"
assert_contains \
  "plan step command includes -out= pointing at RUNNER_TEMP" \
  "$plan_cmd" \
  "-out=/tmp/runner-temp/iac-cicd-tfplan.bin"

# Same requirement applies to the Apply step's own internal plan invocation,
# which also needs a fresh plan file to show and apply.
apply_plan_cmd="$(build_apply_plan_command "tofu" "/tmp/runner-temp" "")"
assert_contains \
  "apply step's internal plan command includes -out= pointing at RUNNER_TEMP" \
  "$apply_plan_cmd" \
  "-out=/tmp/runner-temp/iac-cicd-tfplan.bin"

# Scenario 2: Given a successful plan (exit 0 or 2), when JSON rendering runs,
# then show -json is invoked with the same plan-file path just written.
for plan_exit_code in 0 2; do
  plan_cmd="$(build_plan_command "tofu" "/tmp/runner-temp" "")"
  show_cmd="$(build_plan_show_command "tofu" "/tmp/runner-temp" "$plan_exit_code")"
  plan_file="${plan_cmd#*-out=}"
  plan_file="${plan_file%% *}"
  assert_contains \
    "show -json is invoked with the plan-file path just written (plan exit $plan_exit_code)" \
    "$show_cmd" \
    "show -json $plan_file"
done

# Scenario 3: Given an apply step invocation, when constructed, then it applies
# the plan-file path, not a bare apply with no file argument.
apply_cmd="$(build_apply_command "tofu" "/tmp/runner-temp")"
assert_contains \
  "apply step applies the saved plan-file path" \
  "$apply_cmd" \
  "apply -input=false -auto-approve /tmp/runner-temp/iac-cicd-tfplan.bin"
assert_not_equal \
  "apply step invocation is not a bare apply with no plan-file argument" \
  "$apply_cmd" \
  "tofu apply -input=false -auto-approve"

# Scenario 4: Given a plan invocation that exits 1 (error), when the step logic
# runs, then show -json is not invoked and the step fails.
assert_command_fails \
  "Plan step's show -json is not invoked and the step fails when plan exits 1" \
  build_plan_show_command "tofu" "/tmp/runner-temp" "1"
assert_command_fails \
  "Apply step's show -json is not invoked and the step fails when its internal plan exits 1" \
  build_apply_plan_show_command "tofu" "/tmp/runner-temp" "1"

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi

echo "All scenarios passed"
exit 0
