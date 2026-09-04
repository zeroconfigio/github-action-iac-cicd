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

# Mirrors action.yml's "Policy check (plan)" step's if: condition.
policy_check_should_run() {
  local command="$1"
  local policy_command="$2"

  [ "$command" = "plan" ] && [ -n "$policy_command" ]
}

# Mirrors action.yml's "Policy check (plan)" step's run: block, given a
# plan-json path and a stand-in policy command.
run_policy_check() {
  local plan_json="$1"
  local policy_command="$2"

  IAC_PLAN_JSON="$plan_json" bash -c '
    set -euo pipefail
    if ! '"$policy_command"'; then
      echo "::error::policy check failed"
      exit 1
    fi
  '
}

# Scenario 1: Given policy-command empty, when plan completes, then the
# policy-check step is skipped entirely (no error, no-op).
if policy_check_should_run "plan" ""; then
  echo "FAIL: policy-check step's if: condition runs with an empty policy-command (expected skip)"
  failures=$((failures + 1))
else
  echo "PASS: policy-check step's if: condition skips with an empty policy-command"
fi

# Scenario 2: Given policy-command: 'true', when the step runs, then it
# exits 0 and continues.
if run_policy_check "/tmp/runner-temp/iac-cicd-tfplan.json" "true" > /dev/null 2>&1; then
  echo "PASS: policy-check step exits 0 and continues when policy-command is 'true'"
else
  echo "FAIL: policy-check step did not exit 0 when policy-command is 'true'"
  failures=$((failures + 1))
fi

# Scenario 3: Given policy-command: 'false', when the step runs, then it
# exits nonzero and fails with an error.
if run_policy_check "/tmp/runner-temp/iac-cicd-tfplan.json" "false" > /dev/null 2>&1; then
  echo "FAIL: policy-check step did not fail when policy-command is 'false'"
  failures=$((failures + 1))
else
  echo "PASS: policy-check step exits nonzero and fails when policy-command is 'false'"
fi

# Scenario 4: Given policy-command set and command == 'apply', when this
# step's if: is evaluated, then it does not run.
if policy_check_should_run "apply" "true"; then
  echo "FAIL: policy-check step's if: condition runs on command == 'apply' (expected skip)"
  failures=$((failures + 1))
else
  echo "PASS: policy-check step's if: condition skips on command == 'apply'"
fi

# Scenario 5: Given a policy-command that reads $IAC_PLAN_JSON, when the step
# runs, then it exits 0, proving the var is exported at plan-time.
expected_path="/tmp/runner-temp/iac-cicd-tfplan.json"
if run_policy_check "$expected_path" '[ "$IAC_PLAN_JSON" = "'"$expected_path"'" ]' > /dev/null 2>&1; then
  echo "PASS: IAC_PLAN_JSON is exported to the policy-command's environment at plan-time"
else
  echo "FAIL: IAC_PLAN_JSON was not visible to the policy-command's environment"
  failures=$((failures + 1))
fi

# Mirrors action.yml's "Apply" step's inline policy-check block, guarded by
# policy-command being non-empty.
apply_policy_check_should_run() {
  local policy_command="$1"

  [ -n "$policy_command" ]
}

# Echoes a sentinel standing in for the real apply invocation that follows
# the check in action.yml.
run_apply_policy_check() {
  local plan_json="$1"
  local policy_command="$2"

  bash -c '
    set -euo pipefail
    export IAC_PLAN_JSON="'"$plan_json"'"
    if ! '"$policy_command"'; then
      echo "::error::policy check failed"
      exit 1
    fi
    echo "APPLY_REACHED"
  '
}

# Scenario 1: policy command receives the apply-time plan JSON path via
# IAC_PLAN_JSON.
expected_apply_plan_path="/tmp/runner-temp/iac-cicd-tfplan.json"
if run_apply_policy_check "$expected_apply_plan_path" '[ "$IAC_PLAN_JSON" = "'"$expected_apply_plan_path"'" ]' > /dev/null 2>&1; then
  echo "PASS: IAC_PLAN_JSON is exported to the apply-time policy-command's environment"
else
  echo "FAIL: IAC_PLAN_JSON was not visible to the apply-time policy-command's environment"
  failures=$((failures + 1))
fi

# Scenario 2: a failing check must prevent the sentinel apply logic from
# running.
apply_policy_output="$(run_apply_policy_check "$expected_apply_plan_path" "false" 2>&1 || true)"
if [[ "$apply_policy_output" == *"APPLY_REACHED"* ]]; then
  echo "FAIL: apply logic ran after a failing apply-time policy check"
  failures=$((failures + 1))
else
  echo "PASS: apply logic does not run after a failing apply-time policy check"
fi
assert_command_fails \
  "apply-time policy-check block exits nonzero when policy-command is 'false'" \
  run_apply_policy_check "$expected_apply_plan_path" "false"

# Scenario 3: an empty policy-command skips the block entirely.
if apply_policy_check_should_run ""; then
  echo "FAIL: apply-time policy-check block runs with an empty policy-command (expected skip)"
  failures=$((failures + 1))
else
  echo "PASS: apply-time policy-check block skips with an empty policy-command"
fi

# Scenario 4: in the real action.yml, the apply-time policy-check logic must
# precede the final apply invocation, and neither may use continue-on-error.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action_yml="$script_dir/../action.yml"

policy_check_line=$(grep -n "policy check failed" "$action_yml" | tail -n1 | cut -d: -f1)
apply_invoke_line=$(grep -n 'apply -input=false -auto-approve' "$action_yml" | tail -n1 | cut -d: -f1)

if [ -n "$policy_check_line" ] && [ -n "$apply_invoke_line" ] && [ "$policy_check_line" -lt "$apply_invoke_line" ]; then
  echo "PASS: apply-time policy-check logic appears before the final apply invocation in action.yml"
else
  echo "FAIL: apply-time policy-check logic does not precede the final apply invocation in action.yml"
  failures=$((failures + 1))
fi

if grep -n "continue-on-error: *true" "$action_yml" > /dev/null 2>&1; then
  echo "FAIL: action.yml contains a continue-on-error: true step"
  failures=$((failures + 1))
else
  echo "PASS: action.yml contains no continue-on-error: true step"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi

echo "All scenarios passed"
exit 0
