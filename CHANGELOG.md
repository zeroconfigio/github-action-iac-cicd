# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial composite action: plan on any non-`push` event, apply on `push`,
  state in Cloudflare R2 or AWS S3 via the S3-compatible backend with
  native lockfile locking, selectable with the `backend` input (`r2`
  default, or `s3`).
- Sticky PR comment for plan output (find-and-update, no comment spam).
- Support for both OpenTofu and Terraform, selectable via the `tool` input.
- Example consumer workflow with environment-gated apply.
- `endpoint` input as an escape hatch for other S3-compatible providers
  (Backblaze B2, MinIO, ...), best-effort, not a tuned target.
- `policy-command` input: an optional hook to your own policy tool (OPA/conftest,
  Sentinel, a custom script), checked against the JSON plan at both plan-time
  and apply-time. Nonzero exit fails the run. See the README's "Policy gate"
  section for the `IAC_PLAN_JSON` contract and why it checks twice.
- `aws-role-arn` and `aws-role-session-name` inputs: OIDC auth for
  `backend: s3`, assuming an IAM role via `aws-actions/configure-aws-credentials`
  instead of static access keys. Additive to `access-key-id`/`secret-access-key`
  as inputs, not a replacement, setting both fails loud by design. `s3` only,
  R2 has no OIDC equivalent. See the README's "OIDC for AWS S3" section for
  the trust policy and the required `permissions: id-token: write`.
- Example scheduled drift-detection workflow
  (`examples/drift-detection.yml`): calls the action with no `command:`
  override, relying on the existing safer default (`plan` for any non-`push`
  event) instead of a special drift mode. Opens or updates a single Issue
  carrying a `drift-detection` label when `has-changes == 'true'`, instead
  of filing a new Issue every run. See the README's "Drift detection"
  section.
