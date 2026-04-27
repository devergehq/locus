# Locus

> An agentic AI workflow execution framework that sits between you and your AI coding tool.
> It provides structure, skills, and persistent memory — without locking you to any platform.

**Status:** Early. Core features work (init, platform adapters, skills, agents, delegation, hooks), but APIs and conventions may still shift. Built primarily for the maintainer and early adopters who want structured AI workflows.

---

## What it is

Locus is a single Rust binary that installs a structured workflow framework into `~/.locus/`. It does not replace your AI coding tool — it augments it with:

1. **The Algorithm** — A 7-phase decomposition (OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN) that any AI agent can follow. The Algorithm spec lives in `~/.locus/algorithm/` and is embedded into your platform's system prompt.
2. **Skills** — Composable, multi-mode capabilities (research, council, red-team, first-principles, etc.) defined in `SKILL.md` files. Skills are loaded on demand — nothing is injected into platform subdirectories.
3. **Agents** — Trait-composed agent roles (not character-based personas). Compose an agent from expertise, stance, and approach traits on the fly.
4. **Persistent memory** — Checkpoints, learnings, and project memory stored in `~/.locus/data/` and syncable via git.
5. **Platform adapters** — Minimal, non-destructive integration with Claude Code and OpenCode. Backs up existing config, merges settings, and restores on removal.

## What it isn't

- **Not an AI coding tool.** It does not generate code or chat with you. It structures the workflow *around* your AI tool.
- **Not a plugin or extension.** It lives outside your editor/IDE and communicates via platform hooks.
- **Not platform-specific.** While adapters exist for Claude Code and OpenCode, the framework itself is platform-agnostic.
- **Not commercial software.** MIT licensed, free forever.

## Who it's for

People who:

- Use Claude Code, OpenCode, or similar AI coding tools regularly.
- Want consistent, structured execution from their AI (phased decomposition, verifiable criteria, explicit verification).
- Run multi-agent workflows (debate, red-team, iterative depth) and need trait-based agent composition.
- Want their AI workflow memory, skills, and configurations to persist across machines.

If you just want to chat with an AI and don't care about structured workflows, Locus adds no value.

---

## Quick start

```sh
# 1. Install Locus
cargo install --path crates/locus-cli

# 2. Initialise the framework
locus init

# 3. Connect your AI platform
locus platform add claude-code   # or: locus platform add opencode

# 4. Validate everything
locus doctor
```

After `locus init`, your `~/.locus/` directory contains the Algorithm, skills, agents, protocols, and an empty data directory. After `locus platform add`, your platform's system prompt is updated to bootstrap Locus on every session.

---

## Installation

### From source (recommended for now)

Requires [Rust](https://rustup.rs/) (stable toolchain).

```sh
git clone https://github.com/devergehq/locus.git
cd locus
cargo install --path crates/locus-cli
```

This places the `locus` binary in `~/.cargo/bin/`. Ensure that directory is on your `PATH`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
```

> **Important:** `locus` must be on your `PATH`. Platform adapters configure hooks that call `locus hook <event>` — if the binary isn't resolvable, hooks silently fail.

### Prebuilt binaries (not yet available)

Locus does not currently publish prebuilt releases. The release infrastructure (`cargo-dist`) is configured but not yet active. See [Distribution](#distribution) below.

---

## Platform adapters

Locus connects to your AI coding tool via a **platform adapter**. Adapters are minimal and non-destructive:

- **Claude Code** — writes to `~/.claude/CLAUDE.md` and merges `~/.claude/settings.json`
- **OpenCode** — writes to `~/.config/opencode/AGENTS.md` and merges `~/.config/opencode/opencode.json`

### Adding an adapter

```sh
locus platform add claude-code
```

Pre-existing config files are backed up to `<filename>.pre-locus` before being modified. User settings and non-Locus hooks are preserved.

### Removing an adapter

```sh
locus platform remove claude-code
```

This removes Locus entries from the adapter's config. Restore a pre-Locus backup manually if needed:

```sh
mv ~/.claude/CLAUDE.md.pre-locus ~/.claude/CLAUDE.md
```

### Listing platforms

```sh
locus platform list
```

Shows detection status: installed, config-only, CLI-only, or not installed.

---

## Commands

### Core workflow

```sh
locus init                    # Scaffold ~/.locus/ and detect platforms
locus doctor                  # Validate installation
locus status                  # Dashboard: version, platforms, skills, data size
```

### Platform management

```sh
locus platform list
locus platform add <name>     # claude-code | opencode
locus platform remove <name>
```

### Skills

```sh
locus skill list              # List available skills
locus skill info <id>         # Show skill detail (e.g., research, council)
```

Skills live in `~/.locus/skills/<id>/SKILL.md`. They define workflows, required capabilities, and execution patterns. The Algorithm loads skills on demand — nothing is pre-loaded into every session.

### Agent composition

```sh
locus agent list-traits       # Show all available traits
locus agent compose --traits "security,skeptical,thorough" \
                     --role "Auth reviewer" \
                     --task "Review the login flow for injection risks"
```

Traits are defined in `~/.locus/agents/traits.yaml` across three axes:

- **Expertise** — architecture, implementation, testing, security, research, design, product, data, infrastructure
- **Stance** — skeptical, empirical, rationalist, contrarian, adversarial, systems-thinking, analogical, constructive, pragmatic, affirmative, negative, judge
- **Approach** — thorough, rapid, systematic, iterative, hypothesis-driven, exploratory, structured-output, narrative

Use `--output json` for a structured object instead of a plain prompt string.

### Delegation

```sh
locus delegate run --backend opencode \
                   --task-kind research \
                   --dir /path/to/project \
                   --prompt "Research this topic" \
                   --dry-run
```

Runs a bounded task through an external backend (e.g., OpenCode). Used by skills like Council and RedTeam to spawn parallel agents. See `locus delegate --help` for full options.

### Maintenance

```sh
locus sync                    # Commit and push ~/.locus/data/ via git
locus upgrade                 # Check for updates from GitHub releases
locus update-content          # Sync bundled algorithm/skills/agents from binary
```

### Hooks (invoked by platforms)

```sh
locus hook session-start
locus hook pre-compact
locus hook stop
```

These are called by Claude Code and OpenCode via their hook systems. You do not run them manually.

---

## The Algorithm in 60 seconds

The Locus Algorithm is a 7-phase structured decomposition that any AI agent can apply to non-trivial tasks:

1. **OBSERVE** — Understand the request deeply. Define Ideal State Criteria (ISC): atomic, verifiable, binary pass/fail goals.
2. **THINK** — Pressure-test the plan. Identify riskiest assumptions, run a premortem, check prerequisites.
3. **PLAN** — Validate prerequisites and establish execution order. Sequence dependencies.
4. **BUILD** — Prepare everything needed before execution. Invoke capabilities, do research, scaffold.
5. **EXECUTE** — Perform the actual work. Mark criteria as satisfied immediately when they pass.
6. **VERIFY** — Confirm every criterion is actually met — not assumed. Add evidence.
7. **LEARN** — Extract insights. Persist learnings to disk so future executions improve.

The full specification lives at `~/.locus/algorithm/v1.1.md` after `locus init`.

Key concepts:

- **ISC (Ideal State Criteria)** — Every task must have atomic, verifiable criteria. No compound criteria (no "and").
- **Splitting Test** — If a criterion contains "and", "with", or crosses domain boundaries, split it.
- **Phantom Capability Rule** — Every capability selected must be actually invoked via tool call. Text-only invocation is theatre.
- **Effort levels** — Minimal (<1 min), Standard (<5 min), Extended (<15 min), Advanced (<30 min), Deep (<60 min), Comprehensive (<120 min). Each has a minimum ISC count.

The Algorithm is embedded into your platform's system prompt so every AI session follows it automatically.

---

## What gets installed

After `locus init`:

```
~/.locus/
├── algorithm/          # Algorithm specification (v1.1.md)
├── skills/             # Skill definitions (SKILL.md per skill)
│   ├── council/
│   ├── creative/
│   ├── first-principles/
│   ├── iterative-depth/
│   ├── red-team/
│   ├── research/
│   ├── science/
│   └── ...
├── agents/             # Agent traits and archetypes
│   ├── traits.yaml
│   └── *.md
├── protocols/          # Context management, degradation, memory schema
├── data/               # User data (memory, checkpoints, learnings)
│   ├── memory/
│   ├── learning/
│   └── state/
└── locus.yaml          # Canonical configuration
```

After `locus platform add claude-code`:

- `~/.claude/CLAUDE.md` — Locus bootstrap with Algorithm embedded
- `~/.claude/settings.json` — merged Locus hook entries

After `locus platform add opencode`:

- `~/.config/opencode/AGENTS.md` — Locus bootstrap with Algorithm embedded
- `~/.config/opencode/opencode.json` — merged instructions

**Nothing is written to platform subdirectories like `~/.claude/skills/` or `.opencode/`.** All Locus content stays in `~/.locus/`.

---

## Removal

Locus is non-destructive:

```sh
locus platform remove claude-code   # Remove adapter
locus platform remove opencode      # Remove adapter
rm -rf ~/.locus                     # Delete all Locus data
```

Restore pre-Locus backups if needed:

```sh
mv ~/.claude/CLAUDE.md.pre-locus ~/.claude/CLAUDE.md
```

---

## Architecture

Locus is a Rust workspace with six crates:

| Crate | Purpose |
|-------|---------|
| `locus-cli` | Binary and CLI commands |
| `locus-core` | Core types, traits, and interfaces |
| `locus-adapter-claude` | Claude Code platform adapter |
| `locus-adapter-opencode` | OpenCode platform adapter |
| `locus-tools` | Shared utilities |
| `locus-index` | Project indexing (stub — see Future) |

Design principles:

- **Dependency inversion:** `locus-core` defines interfaces; adapter crates implement them. `locus-core` never depends on adapters.
- **Exhaustive matching:** The `Platform` enum ensures every adapter and config generator handles all platforms. Adding a platform causes compiler errors everywhere it isn't handled.
- **Honest degradation:** Features requiring unsupported platform capabilities are explicitly marked unavailable, never silently degraded.

---

## Distribution

Locus is currently **source-only**. Prebuilt binaries are not published.

The release infrastructure is pre-configured via [`cargo-dist`](https://opensource.axo.dev/cargo-dist/) in `dist.toml`:

- Targets: macOS (Apple Silicon + Intel), Linux (x86_64 + ARM64)
- Installers: shell script, Homebrew formula
- CI: GitHub Actions

To activate releases when ready:

1. Install `cargo-dist`: `cargo install cargo-dist`
2. Run `cargo dist init` to generate GitHub Actions workflow
3. Create a Homebrew tap repo (e.g., `devergehq/homebrew-tap`)
4. Push a git tag: `git tag v0.1.0 && git push origin v0.1.0`

Until then, install from source.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the short version:

1. Open an issue first for anything non-trivial.
2. Run `cargo check`, `cargo test`, and `cargo fmt`.
3. Submit a PR with a clear description.

Response times are side-project pace (days to weeks). If you need faster, please fork.

---

## Future gaps

See [`FUTURE_GAPS.md`](FUTURE_GAPS.md) for capabilities intentionally deferred, including:

- `locus-index` — Rust-native project indexing with tree-sitter and embeddings
- `evals` skill — Prompt and agent evaluation framework
- `browser` skill — Web browsing / scraping workflows
- `create-skill` and `create-cli` internal scaffolding tools

---

## Acknowledgements

Locus is heavily inspired by [Daniel Miessler's Personal AI Infrastructure](https://github.com/danielmiessler/Personal_AI_Infrastructure) (PAI). I started using PAI v4 and found the core ideas — the component system, the Algorithm, and the skill-based approach — to be excellent. Locus is not a fork of PAI; it is a different take on the same problem space, built from scratch in Rust with a fundamentally different architecture and philosophy.

### What Locus took from PAI

- The **component/skill system** — composable, file-based capabilities that the Algorithm loads on demand.
- The **7-phase Algorithm** — OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN, with ISC criteria and the Splitting Test.
- Many **skill workflows** and **prompting patterns** that were refined in PAI and ported or adapted for Locus.

### What Locus changed

| PAI approach | Locus approach |
|---|---|
| Tightly coupled to Claude Code (files live in `~/.claude/`) | Platform-agnostic; lives in `~/.locus/` with minimal, reversible adapters |
| Character-based agent personas (anthropomorphized backstories) | Trait-based agent composition (expertise × stance × approach), backed by research showing personas harm reasoning |
| Teller system for voice interaction (11labs) | Removed — no voice system |
| Positioned as a "personal assistant" | Positioned as a structured workflow overlay — not an assistant, but a framework |
| TypeScript, Python, Shell, Vue, JavaScript | Rust (98%) + Shell (status line only). Single binary, no runtime dependencies |
| No upgrade/uninstall tooling | Full CLI for init, upgrade, sync, doctor, and clean removal |
| Deep integration into platform directories | Clean separation: platform configs are backed up, merged, and restorable |

### Direct Locus credits

- **Daniel Miessler** — for open-sourcing PAI and documenting the ideas that Locus builds on. PAI proved that structured AI workflows are valuable; Locus tries to make them portable, maintainable, and platform-agnostic.
- **The Rust community** — for a language and ecosystem that makes single-binary, cross-platform CLI tools practical.

---

## License

MIT. See [LICENSE](LICENSE).
