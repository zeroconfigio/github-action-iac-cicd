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
directly from other event types (a scheduled drift check, for example).

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `tool` | no | `opentofu` | `opentofu` or `terraform` |
| `tool-version` | no | `latest` | Version to install |
| `working-directory` | no | `.` | Root module directory |
| `command` | no | auto | Override auto-detect (`apply` on `push`, `plan` otherwise) |
| `backend` | no | `r2` | `r2` (Cloudflare R2) or `s3` (AWS S3) |
| `bucket` | yes | | Bucket for state |
| `access-key-id` | yes | | S3-compatible access key ID |
| `secret-access-key` | yes | | S3-compatible secret access key |
| `account-id` | required for `r2` | | Cloudflare account ID (ignored for `s3`, or when `endpoint` is set) |
| `region` | required for `s3` | `auto` for `r2` | Bucket region |
| `endpoint` | no | derived | Override the S3-compatible endpoint URL |
| `state-key` | no | derived | Object key for the state file |
| `extra-args` | no | `` | Extra flags appended to the plan that produces the applied plan file (not to the final `apply <planfile>` call, which can't take flags like `-var-file` once a plan is saved) |
| `comment-on-pr` | no | `true` | Post/update a sticky PR comment on plan |
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

- No policy-as-code, no drift detection, no cost estimation. If you need
  those, look at a full platform (Scalr, Terrakube).
- No generic multi-provider backend abstraction. R2 and AWS S3 are the two
  tuned targets; other S3-compatible providers work through the `endpoint`
  escape hatch on a best-effort basis, see "Other S3-compatible providers"
  above.
- Does not checkout your repo, `actions/checkout` stays the caller's
  responsibility, same convention as `hashicorp/setup-terraform`.

## License

MIT
