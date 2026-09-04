#!/usr/bin/env bash
# Extracts and runs the real run: block from examples/drift-detection.yml's drift-issue step.
set -uo pipefail

failures=0
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow_file="$script_dir/../examples/drift-detection.yml"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# ${{ }} expressions are substituted for real shell values at extraction time.
test_repo="octocat/Hello-World"
test_server_url="https://github.example"
test_run_id="4242"

extracted_script="$work_dir/drift-issue-step.sh"

python3 - "$workflow_file" "$extracted_script" "$test_repo" "$test_server_url" "$test_run_id" <<'PY'
import sys

import yaml

workflow_path, out_path, repo, server_url, run_id = sys.argv[1:6]

with open(workflow_path) as f:
    workflow = yaml.safe_load(f)

steps = workflow["jobs"]["detect"]["steps"]
step = next(s for s in steps if s.get("name") == "Open or update drift Issue")
script = step["run"]

script = script.replace("${{ github.repository }}", repo)
script = script.replace("${{ github.server_url }}", server_url)
script = script.replace("${{ github.run_id }}", run_id)

if "${{" in script:
    sys.stderr.write("unstubbed GitHub Actions expression left in extracted script\n")
    sys.exit(1)

with open(out_path, "w") as f:
    f.write("#!/usr/bin/env bash\n")
    f.write(script)
PY

if [ $? -ne 0 ]; then
  echo "FAIL: could not extract the drift-issue step's run: text from $workflow_file"
  exit 1
fi

# Pulled from the extracted text, so this stays in sync with the real marker.
marker="$(sed -n 's/^marker="\(.*\)"$/\1/p' "$extracted_script")"

if [ -z "$marker" ]; then
  echo "FAIL: could not read the marker value out of the extracted script"
  exit 1
fi

# Stub gh logs every call's verb + path; returns GH_STUB_ISSUES_RESPONSE for GET.
stub_dir="$work_dir/bin"
mkdir -p "$stub_dir"

cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "api" ]; then
  echo "gh-stub: unsupported subcommand '${1:-}'" >&2
  exit 1
fi
shift

verb="GET"
path=""

while [ $# -gt 0 ]; do
  case "$1" in
    -X)
      verb="$2"
      shift 2
      ;;
    -F|-f)
      shift 2
      ;;
    --paginate)
      shift
      ;;
    *)
      path="$1"
      shift
      ;;
  esac
done

echo "$verb $path" >> "$GH_STUB_LOG"

case "$verb" in
  GET)
    printf '%s' "${GH_STUB_ISSUES_RESPONSE:-[]}"
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$stub_dir/gh"

log_file="$work_dir/gh-stub.log"

# Fresh stub log per call, so no scenario depends on another's leftovers.
run_extracted_script() {
  local issues_response="$1"

  : > "$log_file"

  PATH="$stub_dir:$PATH" \
  GH_TOKEN="dummy-token" \
  RUNNER_TEMP="$work_dir" \
  GH_STUB_LOG="$log_file" \
  GH_STUB_ISSUES_RESPONSE="$issues_response" \
  bash "$extracted_script"
}

# Scenario 1: no existing labeled+marked issue (empty array) creates one via POST, not PATCH.
if run_extracted_script "[]" > /dev/null 2>&1; then
  if grep -qx "POST repos/$test_repo/issues" "$log_file" && ! grep -q "^PATCH " "$log_file"; then
    echo "PASS: no existing labeled+marked issue results in a POST to create the issue, not a PATCH"
  else
    echo "FAIL: no existing labeled+marked issue did not POST as expected (log: $(cat "$log_file"))"
    failures=$((failures + 1))
  fi
else
  echo "FAIL: extracted script exited nonzero for the no-existing-issue scenario"
  failures=$((failures + 1))
fi

# Scenario 2: an existing labeled+marked issue (number 42) is updated via PATCH, not POST.
existing_issue_response='[{"number": 42, "body": "'"$marker"'\nDrift detected: the last scheduled plan found changes outside this pipeline."}]'

if run_extracted_script "$existing_issue_response" > /dev/null 2>&1; then
  if grep -qx "PATCH repos/$test_repo/issues/42" "$log_file" && ! grep -q "^POST " "$log_file"; then
    echo "PASS: an existing labeled+marked issue (42) results in a PATCH, not a POST"
  else
    echo "FAIL: existing labeled+marked issue did not PATCH as expected (log: $(cat "$log_file"))"
    failures=$((failures + 1))
  fi
else
  echo "FAIL: extracted script exited nonzero for the existing-issue scenario"
  failures=$((failures + 1))
fi

# A labeled issue with no body (GitHub allows this) must not crash the script.
null_body_response='[{"number": 7, "body": null}]'

if run_extracted_script "$null_body_response" > /dev/null 2>&1; then
  if grep -qx "POST repos/$test_repo/issues" "$log_file" && ! grep -q "^PATCH " "$log_file"; then
    echo "PASS: a labeled issue with a null body is treated as no match, still POSTs"
  else
    echo "FAIL: a null-body issue did not fall through to POST as expected (log: $(cat "$log_file"))"
    failures=$((failures + 1))
  fi
else
  echo "FAIL: extracted script crashed on a labeled issue with a null body"
  failures=$((failures + 1))
fi

# Scenario 3: has-changes == false is the step's own if: condition, verified by grep, not execution.
if grep -A1 "name: Open or update drift Issue" "$workflow_file" \
  | grep -q "if: steps.iac.outputs.has-changes == 'true'"; then
  echo "PASS: the drift-issue step is gated by if: steps.iac.outputs.has-changes == 'true'"
else
  echo "FAIL: the drift-issue step is not gated by the expected has-changes if: condition"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi

echo "All scenarios passed"
exit 0
