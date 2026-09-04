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
