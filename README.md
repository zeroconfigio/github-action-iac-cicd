# github-action-iac-cicd

A zero-config GitHub Action for OpenTofu/Terraform: plan on every pull request,
apply on merge, state stored in Cloudflare R2. No HCP Terraform, no Atlantis
server, no Kubernetes cluster. State never touches the local repo checkout.

## Why

State stored inside a repo checkout is a real risk the moment that repo is
public, or even just widely cloned: secrets in plan output, resource IDs, tfvars
values, all sitting in git history. `iac-cicd` keeps state in Cloudflare R2
(free tier: 10 GB storage, 1M write + 10M read ops/month, no egress fees) and
drives plan/apply from GitHub-hosted runners, so the only two things your
project needs an account with are GitHub and Cloudflare.

## Quickstart

1. **Create an R2 bucket** in the Cloudflare dashboard (or via `wrangler r2 bucket create <name>`).
2. **Create an R2 API token** scoped to that bucket only (Cloudflare dashboard
   → R2 → Manage API Tokens → Create API Token → Object Read & Write, scoped
   to the one bucket). This gives you an access key ID and secret access key.
3. **Add four repo secrets** (Settings → Secrets and variables → Actions):
   `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
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
   all of it, so this block stays empty forever.

5. **Copy the example workflow.** See [`examples/plan-apply.yml`](examples/plan-apply.yml)
   for a complete plan-on-PR / apply-on-merge pipeline, or the minimal form below:

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
             r2-account-id: ${{ secrets.R2_ACCOUNT_ID }}
             r2-access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
             r2-secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
             r2-bucket: ${{ secrets.R2_BUCKET }}
   ```

That's it. On a pull request, this posts (and keeps updating, no comment
spam) a sticky comment with the plan. On merge to the default branch, it
applies. Both directions read/write the same state key in R2, derived by
default from `<owner>/<repo>[/<working-directory>]/terraform.tfstate`, so
multiple root modules in one repo (pass different `working-directory` values)
don't collide.

The four R2 secrets above only authenticate the **state backend**. Whatever
you're actually provisioning (AWS, Cloudflare, GitHub, ...) needs its own
provider credentials, wired into the same job through your own secrets and
`provider {}` blocks. `iac-cicd` never sees or needs those.

## Manual approval before apply

`iac-cicd` runs inside whatever job calls it, so approval gates are a
property of that job, not something the action can enforce internally. Put
the apply job behind a [GitHub Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
with a required reviewer, see `examples/plan-apply.yml` for the full pattern.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `tool` | no | `opentofu` | `opentofu` or `terraform` |
| `tool-version` | no | `latest` | Version to install |
| `working-directory` | no | `.` | Root module directory |
| `command` | no | auto | Override auto-detect (`plan` on `pull_request`, `apply` otherwise) |
| `r2-account-id` | yes | | Cloudflare account ID |
| `r2-access-key-id` | yes | | R2 API token access key ID |
| `r2-secret-access-key` | yes | | R2 API token secret access key |
| `r2-bucket` | yes | | R2 bucket for state |
| `state-key` | no | derived | Object key for the state file |
| `extra-args` | no | `` | Extra flags appended to plan/apply |
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

Cloudflare encrypts all R2 objects at rest by default, that's the baseline
for both tools. OpenTofu additionally supports a native
[`encryption {}`](https://opentofu.org/docs/language/state/encryption/)
block for client-side state encryption before it ever reaches R2, this is
OpenTofu-only (not available in Terraform) and is not configured by this
action, add it to your own `terraform {}` block if you want it; `iac-cicd`
does not touch that block.

## What this deliberately doesn't do

- No policy-as-code, no drift detection, no cost estimation. If you need
  those, look at a full platform (Scalr, Terrakube).
- No multi-cloud state backend abstraction, R2 (S3-compatible) is the only
  target. AWS S3 works unmodified against the same backend config if you
  swap the endpoint, but that's out of scope for a "zero config" tool with
  one opinion.
- Does not checkout your repo, `actions/checkout` stays the caller's
  responsibility, same convention as `hashicorp/setup-terraform`.

## License

MIT
