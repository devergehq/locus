# Contributing to Locus

Thanks for considering contributing. This project is small and maintained in spare time, so the process is intentionally lightweight.

## Before you start

- **Open an issue first** for anything non-trivial (new features, breaking changes, architectural shifts). This avoids wasted effort if the direction doesn't align.
- **Bug fixes and docs improvements** don't need an issue — a PR with a clear description is enough.

## How to contribute

1. Fork the repo and create a branch.
2. Make your changes.
3. Run `cargo fmt --all`, `cargo clippy --all-targets --all-features` and `cargo test --workspace`.
4. Submit a PR with a clear description of what changed and why.

## What we're looking for

- **Documentation improvements** — if something was confusing, fixing the docs is as valuable as fixing the code.
- **Bug fixes** — especially in platform adapters or the CLI.
- **New skills** — see `skills/` for examples. Skills should be self-contained, documented, and follow the existing `SKILL.md` frontmatter format.
- **Platform adapters** — if you want to add support for a new AI coding platform, open an issue first to discuss the adapter interface.

## What we're not looking for

- **Large refactors without discussion** — the architecture is intentionally opinionated.
- **New dependencies** — Locus aims to stay lightweight. Every dependency needs justification.
- **Breaking changes to the Algorithm** — the 7-phase structure is core to the framework. Changes need broad consensus.

## Toolchain

The Rust toolchain is pinned in `rust-toolchain.toml` to **1.93**, with the
`rustfmt` and `clippy` components. rustup reads that file automatically, so
there is no setup beyond having rustup installed.

`1.93` is a channel, not an exact version: it floats across patch releases.
A CI runner installing fresh gets the newest 1.93.x, while a machine that
installed 1.93.0 months ago keeps it, because rustup does not auto-update an
already-installed channel. Those two can disagree about formatting. If the
`rustfmt` check fails on something you cannot reproduce, run `rustup update`
first.

Please don't bump the pin casually. Formatting output varies between rustfmt
releases, so a bump reformats files across the tree and conflicts with every
open PR. If a bump is needed, land it on its own, on an empty PR queue.

## Code style

- Run `cargo fmt --all` before committing. CI checks this.
- Run `cargo clippy --all-targets --all-features` and address warnings.
- Follow existing module structure and naming conventions.

## CI

Every pull request runs `.github/workflows/ci.yml`:

| Check | Runs on |
| --- | --- |
| `rustfmt` | ubuntu-latest |
| `clippy` | ubuntu-latest |
| `test` | ubuntu-latest + macos-14 |

All three must pass. `clippy` runs with `-D warnings`, so a new warning fails
the build rather than scrolling past — the tree is at zero warnings and the
point of the check is to keep it there.

"Must pass" is about the code, not about the merge button. A workflow cannot
block a merge by itself; that takes marking the check as required in the
branch-protection rule for `master`, which is a repository setting rather than
anything in this repo.

"Blocking-capable" rather than "blocking": a workflow cannot block a merge by
itself. That takes marking the check as required in the branch-protection rule
for `master`, which is a repository setting rather than anything in this repo.

## Response times

This is a side project. Expect days to weeks for review. If you need faster turnaround, please fork.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
