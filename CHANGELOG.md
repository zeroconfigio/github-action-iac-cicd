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
- `.github/dependabot.yml`: weekly `github-actions` update checks,
  covering every pinned SHA in `action.yml` and the workflow files.
- `SECURITY.md`: documents the SHA-pinning verification practice and
  points to GitHub's private vulnerability reporting as the disclosure
  channel.
- `.github/workflows/release.yml`: on a `v*` tag push, archives the
  tagged tree and attests it with `actions/attest-build-provenance`,
  then creates a GitHub Release from that archive. See the README's
  "Supply chain" section for exactly what the attestation does and does
  not prove.
- README "Supply chain" section: Dependabot cadence, the `SECURITY.md`
  link, the release attestation's scope and limits, and a manual
  follow-up note to enable tag protection on `v*` once `v1` is tagged.

### Notes

- `v1` hasn't been tagged yet. Before it is, a few things still need a
  real, live run rather than a static check: a plan/apply against a real
  R2 bucket and a real S3 bucket, a `policy-command` failure proven to
  block a real `apply` (not just a step that reports failure), and a
  real tag push exercised through `release.yml` end to end. Once `v1`
  exists, tag protection on `v*` also needs to be enabled by hand in the
  repo's Settings, see the README's "Supply chain" section.
