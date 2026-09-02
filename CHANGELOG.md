# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial composite action: plan on `pull_request`, apply on push, state in
  Cloudflare R2 via the S3-compatible backend with native lockfile locking.
- Sticky PR comment for plan output (find-and-update, no comment spam).
- Support for both OpenTofu and Terraform, selectable via the `tool` input.
- Example consumer workflow with environment-gated apply.
