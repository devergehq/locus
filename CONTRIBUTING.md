# Contributing to Locus

Thanks for considering contributing. This project is small and maintained in spare time, so the process is intentionally lightweight.

## Before you start

- **Open an issue first** for anything non-trivial (new features, breaking changes, architectural shifts). This avoids wasted effort if the direction doesn't align.
- **Bug fixes and docs improvements** don't need an issue — a PR with a clear description is enough.

## How to contribute

1. Fork the repo and create a branch.
2. Make your changes.
3. Run `cargo check` and `cargo test`.
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

## Code style

- Run `cargo fmt` before committing.
- Use `cargo clippy` and address warnings.
- Follow existing module structure and naming conventions.

## Response times

This is a side project. Expect days to weeks for review. If you need faster turnaround, please fork.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
