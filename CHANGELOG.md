# Changelog

All notable changes to Locus are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Locus uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — on a pre-1.0 line,
which puts breaking changes in the MINOR position.

`Cargo.toml`'s `[workspace.package]` version is the source of truth. A release
tag must equal that version with a leading `v`; `.github/workflows/release.yml`
refuses to build when they disagree.

## [0.3.0] — 2026-09-13

Two breaking changes shipped on master under a patch version. This release is
where the version catches up with them — and it is the release that makes the
plugin obtainable at all, because `locus upgrade` pulls from GitHub Releases and
the newest one, `v0.2.1`, predates the plugin entirely.

### Breaking

- **Locus ships as a Claude Code plugin** (`5b45c02`, DEV-579). The Algorithm
  moves out of a ~32 KB always-on block in `CLAUDE.md` and into the
  `locus-algorithm` skill, loaded on invocation rather than on every session.
  Classification is injected next to every prompt by a `UserPromptSubmit` hook
  and verified at turn end, instead of being asked for once in prose.
- **`locus platform add claude-code` no longer mutates Claude Code's own
  config** (`99ba517`, DEV-608), and `locus platform remove` exists to undo an
  install. Anything that relied on Locus writing into `~/.claude/settings.json`
  must move to the plugin.

### Added

- `.claude-plugin/marketplace.json`, so the plugin can be installed rather than
  only `--plugin-dir`'d (DEV-616):

      claude plugin marketplace add devergehq/locus
      claude plugin install locus@locus

  The entry sources the plugin from the repo root, not `dist/plugin`, because
  `/dist` is gitignored and `marketplace add` fetches a git ref.
- `locus doctor` health checks that can actually fail, rather than reporting
  success unconditionally (`51a7b4c`, DEV-506).
- An ISC ceiling and a recorded-exception path in the Algorithm, so a criteria
  count outside its tier's range is visible and argued instead of padded
  (`2384970`).

### Changed

- All six hooks run through one mechanism in the binary (`locus hook <event>`)
  with no Python dependency (`d6dc1c7`, DEV-610). The shell wrapper remains only
  to detect a missing binary, which the binary cannot do for itself.
- The Rust toolchain is pinned to 1.93 (`a8e328a`, DEV-611) and release builds
  resolve it from `rust-toolchain.toml` via `rustup show` + `rustup target add`
  rather than a separately-installed `stable` (`ff2c4dc`, DEV-611). Targets are
  installed per toolchain; the previous arrangement would have left the pinned
  toolchain with no std for `x86_64-apple-darwin`, the one genuinely
  cross-compiled target.

### Fixed

- Delegation sandboxes no longer destroy their own credentials (`f57b4b2`,
  DEV-505). Shipping a release without this would have meant the first version
  anyone installed still truncated their OpenCode auth.
- The `Stop` hook blocks on skill invocation only, and logs the post-recovery
  outcome (`7476f9a`, DEV-580).
- Delegation test roots no longer collide (`ccf5f9a`, DEV-613).

### Note on the plugin and the binary

Installing the plugin does not install the `locus` binary — it is per-platform
and built rather than vendored, so a git-cloned plugin carries none. Until the
binary is on `PATH`, all six hooks take the missing-binary path: loud, and never
blocking. **The release assets attached to this tag are what make the plugin
functional**, which is why DEV-616 (installable) and this release (functional)
are two halves of one deliverable rather than a feature and its housekeeping.

## [0.2.1] — 2026-08-16

Earlier releases are recorded in the
[GitHub Releases](https://github.com/devergehq/locus/releases) history.

[0.3.0]: https://github.com/devergehq/locus/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/devergehq/locus/releases/tag/v0.2.1
