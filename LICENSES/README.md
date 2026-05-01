# Third-party licence texts

This directory holds the verbatim licence text of any third-party project
that is **vendored** into a release tarball or container image.

It is intentionally empty in the source repository: `linux-dual-wan-failover`
itself is MIT-licensed (see `../LICENSE`) and depends on
`bash-production-toolkit` only at install time, not as a vendored copy.

If a downstream packager bundles a vendored toolkit (for example via
`git subtree`), drop the toolkit's `LICENSE` file here as
`bash-production-toolkit-LICENSE` to comply with the MIT attribution
requirement. See `../NOTICE` for details.
