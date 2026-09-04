# Security Policy

## Action pinning

Every third-party action this repo uses, in `action.yml` and in the
workflow and example files, is pinned to a full commit SHA with a
version-tag comment next to it, for example:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

The comment is a label for humans. The SHA is what actually runs. A
mutable tag like `@v7` can be moved to point at different code later,
a pinned SHA can't.

You don't have to take the tag-to-SHA mapping on faith. Check it
yourself:

```bash
git ls-remote --tags https://github.com/actions/checkout
```

Find the tag named in the comment (`v7.0.1` in the example above) and
confirm its commit matches the SHA pinned in the `uses:` line. If they
don't match, treat it as a problem and open an issue.

## Reporting a vulnerability

Report vulnerabilities through GitHub's private vulnerability
reporting for this repo: go to the repo's **Security** tab, then
**Report a vulnerability**. This sends the report privately to the
maintainers instead of a public issue, and keeps the conversation in
one place.

## Supported versions

This is a GitHub Action, not a versioned library with a support
matrix. Only the latest tagged release gets security fixes. Update
your pin to the newest tag when a fix ships.
