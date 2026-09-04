# github-action-iac-cicd

A zero-config GitHub Action for OpenTofu/Terraform: plan on every pull request,
apply on merge, state stored in Cloudflare R2 or AWS S3. No HCP Terraform, no
Atlantis server, no Kubernetes cluster. State never touches the local repo
checkout.

## Why

State stored inside a repo checkout is a real risk the moment that repo is
public, or even just widely cloned: secrets in plan output, resource IDs, tfvars
values, all sitting in git history. `iac-cicd` keeps state in an S3-compatible
bucket, either Cloudflare R2 (free tier: 10 GB storage, 1M write + 10M read
ops/month, no egress fees) or plain AWS S3, and drives plan/apply from
GitHub-hosted runners. R2 needs only a Cloudflare account beside GitHub; S3
needs only an AWS account.

## Quickstart

1. **Create a bucket.**
   - R2: Cloudflare dashboard → R2, or `wrangler r2 bucket create <name>`.
   - S3: AWS Console → S3, or `aws s3 mb s3://<name> --region <region>`.
2. **Create scoped credentials** for that bucket only.
   - R2: Cloudflare dashboard → R2 → Manage API Tokens → Create API Token →
     Object Read & Write, scoped to the one bucket.
   - S3: an IAM user or role with a policy limited to that one bucket
     (`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`).
3. **Add repo secrets** (Settings → Secrets and variables → Actions):
   - R2: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
   - S3: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, plus the
     bucket's region.
4. **Add one empty backend block** to your OpenTofu/Terraform config, this is
   the only line this tool asks you to commit:

   ```hcl
   terraform {
     backend "s3" {}
   }
   ```

   Partial backend configuration is a language requirement in both OpenTofu
   and Terraform: the block must exist, but everything inside it (bucket,
   key, region, credentials) is supplied at `init` time. `iac-cicd` supplies
   all of it, so this block stays empty forever. Yes, the block is literally
   named `"s3"` even for R2, R2 is consumed through its S3-compatible API.

5. **Copy the example workflow.** See [`examples/plan-apply.yml`](examples/plan-apply.yml)
   for a complete plan-on-PR / apply-on-merge pipeline, or the minimal form below.

   Cloudflare R2 (`backend` defaults to `r2`):

   ```yaml
   name: iac
   on:
     pull_request:
     push:
       branches: [main]

   permissions:
     contents: read
     pull-requests: write

   jobs:
     iac:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v5
         - uses: zeroconfigio/github-action-iac-cicd@v1
           with:
             account-id: ${{ secrets.R2_ACCOUNT_ID }}
             access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
             secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
             bucket: ${{ secrets.R2_BUCKET }}
   ```

   AWS S3, same workflow, three lines different:

   ```yaml
         - uses: zeroconfigio/github-action-iac-cicd@v1
           with:
             backend: s3
             region: us-east-1
             access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
             secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
             bucket: ${{ secrets.AWS_BUCKET }}
   ```

That's it. On a pull request, this posts (and keeps updating, no comment
spam) a sticky comment with the plan. On merge to the default branch, it
applies. Both directions read/write the same state key, derived by default
from `<owner>/<repo>[/<working-directory>]/terraform.tfstate`, so multiple
root modules in one repo (pass different `working-directory` values) don't
collide.

The credentials above only authenticate the **state backend**. Whatever
you're actually provisioning (AWS, Cloudflare, GitHub, ...) needs its own
provider credentials, wired into the same job through your own secrets and
`provider {}` blocks. `iac-cicd` never sees or needs those.

### Other S3-compatible providers

Set `backend: s3` and pass `endpoint` explicitly (Backblaze B2, MinIO, and
similar). This is the escape hatch, not a supported target: `iac-cicd` only
tunes its defaults (`use_path_style`, checksum/validation skips, `encrypt`)
for R2 and real AWS S3, a third provider may need `extra-args` or may not
work at all depending on how closely it follows the S3 API.

## Manual approval before apply

`iac-cicd` runs inside whatever job calls it, so approval gates are a
property of that job, not something the action can enforce internally. Put
the apply job behind a [GitHub Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
with a required reviewer, see `examples/plan-apply.yml` for the full pattern.

`command` auto-detect treats `plan` as the safe default for any event that
isn't `push`, not just `pull_request`. The shipped `examples/plan-apply.yml`
is unaffected by this: its `plan` job already gates on
`github.event_name == 'pull_request'` and its `apply` job gates on
`github.event_name == 'push'`, so neither job ever hits the action with any
other event type. This only matters for consumers that call the action
directly from other event types (a scheduled drift check, for example, see
[Drift detection](#drift-detection)).

## Policy gate

`policy-command` is an optional hook. It's not a bundled policy engine,
`iac-cicd` doesn't ship or install one. Point it at whatever policy tool
you already use (OPA/conftest, Sentinel, a custom script) and the action
runs it for you.

The command receives the run's `terraform show -json`-rendered plan via the
`IAC_PLAN_JSON` env var, a path to the plan file on disk. A nonzero exit
fails the check, which fails the job.

It runs twice: once at plan-time, once at apply-time. That's deliberate,
not redundant. Plan and apply are separate CI runs on separate trigger
events, a PR's `plan` and the later merge's `apply` are different
invocations. So this doesn't guarantee the plan a reviewer saw on the PR is
exactly what gets applied at merge time. What it does guarantee: the hook
always sees, and can block, exactly what's about to happen, immediately
before it happens, in both places where "about to happen" occurs. That's
defense-in-depth against a bypassed branch-protection check, like an admin
force-merge or a required-check list someone set up wrong, not extra
safety for its own sake.

```yaml
policy-command: "conftest test --policy ./policy $IAC_PLAN_JSON"
```

`conftest`/OPA above is just an example. `iac-cicd` doesn't install or
require it, or any other policy tool. Your own workflow needs to install
whatever `policy-command` points at before this action's step runs.

## OIDC for AWS S3

For `backend: s3`, you can skip long-lived AWS keys and assume an IAM role
through GitHub's OIDC token instead. Set `aws-role-arn` (and optionally
`aws-role-session-name`) and `iac-cicd` assumes that role via
`aws-actions/configure-aws-credentials` before running `init`. This only
applies to `backend: s3`, R2 has no OIDC equivalent, it authenticates
through its own API token.

`aws-role-arn` is additive to `access-key-id`/`secret-access-key` as
inputs, not a replacement for them: its presence is what selects OIDC auth
over static keys. If you set both `aws-role-arn` and the static keys, the
action fails loud with a validation error instead of silently picking one.
That's by design.

The calling job needs `permissions: id-token: write`. `iac-cicd` can't
grant that permission on your behalf, GitHub permissions are set at the
workflow or job level only, an action included in a job has no way to add
scopes to it. If that permission is missing,
`aws-actions/configure-aws-credentials` fails at runtime with AWS's own
`AssumeRoleWithWebIdentity` error, not a message from this action.

You also need the GitHub OIDC provider already registered in your AWS
account. That's a one-time AWS account setup step this action doesn't
perform for you, see
[GitHub's docs on configuring OpenID Connect in AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
for how to set it up.

A trust policy scoped to the consumer repo looks like this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:*"
        }
      }
    }
  ]
}
```

Minimal `with:` block for OIDC:

```yaml
permissions:
  id-token: write

steps:
  - uses: zeroconfigio/github-action-iac-cicd@v1
    with:
      backend: s3
      region: us-east-1
      aws-role-arn: arn:aws:iam::123456789012:role/iac-cicd-deploy
      bucket: ${{ secrets.AWS_BUCKET }}
```

No `access-key-id`/`secret-access-key` needed, the role is assumed
directly.

## Drift detection

`iac-cicd` has no dedicated "drift" mode, drift detection is just the same
plan/apply primitives run on a schedule. See
[`examples/drift-detection.yml`](examples/drift-detection.yml) for a
complete `on: schedule` (plus `workflow_dispatch` for manual runs) workflow
that calls the action with no `command:` override. Because the triggering
event isn't `push`, the auto-detect default resolves to `plan` (see
[Manual approval before apply](#manual-approval-before-apply)), so a
scheduled run never applies anything on its own, it only reports what's
changed outside the pipeline.

When the action's `has-changes` output is `'true'`, the example's follow-up
step opens or updates a single GitHub Issue instead of filing a new one on
every run. It tags the Issue with a `drift-detection` label and searches
only issues carrying that label for its marker before deciding whether to
`PATCH` an existing Issue or `POST` a new one, so the search stays bounded
instead of scanning every open issue in the repo.

## Supply chain

`.github/dependabot.yml` watches every pinned `github-actions` SHA, in
`action.yml` and in the workflow files, on a weekly schedule, and opens a
PR when a pin goes stale.

See [`SECURITY.md`](SECURITY.md) for how to verify a pin yourself and
where to report a vulnerability, this README doesn't repeat that here.

On a `v*` tag push, `.github/workflows/release.yml` archives the tagged
tree and attests it with `actions/attest-build-provenance`. The
attestation proves one specific thing: a tarball of the tagged tree was
produced by that workflow, in this repo, for that tag. It's not a full
build-provenance chain for a compiled artifact, this project doesn't
produce one, there's no compiled binary or container image for a chain
like that to cover. A real guarantee, a narrower one than the phrase
"build provenance" might suggest by itself.

**Manual follow-up, not something any workflow configures:** once `v1`
is tagged, enable tag protection on `v*` in the repo's Settings
(Rulesets, or branch/tag protection). Without it, the tag could be
silently repointed at different code later, and nothing in this repo's
workflows would catch that.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `tool` | no | `opentofu` | `opentofu` or `terraform` |
| `tool-version` | no | `latest` | Version to install |
| `working-directory` | no | `.` | Root module directory |
| `command` | no | auto | Override auto-detect (`apply` on `push`, `plan` otherwise) |
| `backend` | no | `r2` | `r2` (Cloudflare R2) or `s3` (AWS S3) |
| `bucket` | yes | | Bucket for state |
| `access-key-id` | required unless `aws-role-arn` is set (`s3`), or always (`r2`) | | S3-compatible access key ID |
| `secret-access-key` | required unless `aws-role-arn` is set (`s3`), or always (`r2`) | | S3-compatible secret access key |
| `aws-role-arn` | no | | IAM role ARN to assume via OIDC, `s3` only, see [OIDC for AWS S3](#oidc-for-aws-s3) |
| `aws-role-session-name` | no | `iac-cicd` | Session name used when assuming `aws-role-arn` |
| `account-id` | required for `r2` | | Cloudflare account ID (ignored for `s3`, or when `endpoint` is set) |
| `region` | required for `s3` | `auto` for `r2` | Bucket region |
| `endpoint` | no | derived | Override the S3-compatible endpoint URL |
| `state-key` | no | derived | Object key for the state file |
| `extra-args` | no | `` | Extra flags appended to the plan that produces the applied plan file (not to the final `apply <planfile>` call, which can't take flags like `-var-file` once a plan is saved) |
| `comment-on-pr` | no | `true` | Post/update a sticky PR comment on plan |
| `policy-command` | no | `` | Command checked against the JSON plan at plan-time and apply-time; nonzero exit fails the run, see [Policy gate](#policy-gate) |
| `github-token` | no | job token | Token used to post the PR comment |

## Outputs

| Output | Description |
|---|---|
| `exitcode` | Exit code of the plan/apply command (`0` = no changes, `2` = plan has changes) |
| `has-changes` | `'true'` if the plan detected changes |

## Locking and versions

State locking uses each backend's native S3 conditional-write lock
(`use_lockfile = true`), not DynamoDB. This requires **OpenTofu ≥ 1.10** or
**Terraform ≥ 1.11**; both are the default `latest` resolves to today. If you
pin `tool-version` below those, locking silently fails to protect concurrent
runs, set your project's `required_version` accordingly so mismatches fail
loud instead of quiet.

## Encryption at rest

Both R2 and S3 encrypt objects at rest by default (S3 has since 2023,
unconditionally). For `backend: s3`, `iac-cicd` also sets the backend's
`encrypt = true` flag, which additionally requests SSE on every state write;
for `backend: r2` it's left `false`, R2's S3-compatible API doesn't support
that flag the same way AWS does. Either way, OpenTofu additionally supports
a native [`encryption {}`](https://opentofu.org/docs/language/state/encryption/)
block for client-side encryption before state ever reaches the bucket, this
is OpenTofu-only (not available in Terraform) and is not configured by this
action, add it to your own `terraform {}` block if you want it; `iac-cicd`
does not touch that block.

## What this deliberately doesn't do

- No bundled policy engine, no cost estimation. `policy-command` (see
  [Policy gate](#policy-gate)) is a hook to your own policy tool, not a
  built-in one. Drift detection isn't a special mode either, it's the same
  plan primitives on a schedule, see [Drift detection](#drift-detection).
  If you need cost estimation, look at a full platform (Scalr, Terrakube).
- No generic multi-provider backend abstraction. R2 and AWS S3 are the two
  tuned targets; other S3-compatible providers work through the `endpoint`
  escape hatch on a best-effort basis, see "Other S3-compatible providers"
  above.
- Does not checkout your repo, `actions/checkout` stays the caller's
  responsibility, same convention as `hashicorp/setup-terraform`.

## License

MIT
