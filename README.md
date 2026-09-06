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

### Prebuilt binaries

Every tagged release publishes prebuilt `locus` binaries on the
[Releases page](https://github.com/devergehq/locus/releases) for:

| Platform | Architecture | Asset |
|----------|--------------|-------|
| macOS | Apple Silicon | `locus-aarch64-apple-darwin.tar.gz` |
| macOS | Intel | `locus-x86_64-apple-darwin.tar.gz` |
| Linux | x86_64 | `locus-x86_64-unknown-linux-gnu.tar.gz` |
| Linux | ARM64 | `locus-aarch64-unknown-linux-gnu.tar.gz` |
| Windows | x86_64 | `locus-x86_64-pc-windows-msvc.tar.gz` |

Download the archive for your platform, extract the `locus` binary (each archive
ships a matching `.sha256` to verify the download), and put it somewhere on your
`PATH`:

```sh
# macOS (Apple Silicon) example
curl -LO https://github.com/devergehq/locus/releases/latest/download/locus-aarch64-apple-darwin.tar.gz
tar -xzf locus-aarch64-apple-darwin.tar.gz
mv locus ~/.local/bin/    # any directory on your PATH
locus doctor
```

On Windows, `tar` is built into modern PowerShell/Command Prompt, so the same
`tar -xzf` works; move `locus.exe` onto your `PATH`.

### Staying up to date

Once you have any `locus` binary installed, upgrade in place — no re-download needed:

```sh
locus upgrade          # fetch and install the latest release
locus upgrade --check  # just report whether a newer version exists
```

`locus upgrade` pulls the correct prebuilt asset for your platform from the
GitHub Releases above and replaces the running binary.

### As a Claude Code plugin (preview)

Locus also ships as a Claude Code plugin. The plugin installs, disables and
uninstalls like any other — it never edits `~/.claude/settings.json`, and
sharing it with someone else does not involve talking them through hand-edits
to their own `CLAUDE.md`.

The two install paths **coexist**. Nothing about the binary install changes;
the plugin is additive, so you can load it alongside and compare.

```sh
./scripts/build-plugin.sh            # assemble dist/plugin/
claude --plugin-dir dist/plugin      # load it for one session
```

What the plugin does differently:

| | Binary install | Plugin |
|---|---|---|
| Algorithm | ~32 KB always-on in `CLAUDE.md` | `locus-algorithm` skill, ~110 tok always-on |
| Classification | asked for in prose | injected next to **every** prompt, then verified at turn end |
| Hooks | merged into your `settings.json` | registered by the plugin, removed when you remove it |

Three hooks carry it:

- **`UserPromptSubmit`** injects `hooks/dispatcher.txt` (781 bytes) as
  `additionalContext`. Compliance decay is a distance problem; injecting on
  every turn resets the distance instead of loading the instruction once and
  hoping it is still salient thirty thousand tokens later.
- **`Stop`** checks that a turn which classified itself non-trivial actually
  invoked the skill. If not it blocks **once** and says what was missed. It
  deliberately does *not* block on a missing classification line — the line is
  nearly free to emit and the skill invocation is the expensive behaviour, so
  gating on either would teach the model to produce the cheap half. The line is
  still recorded on every turn; it is a signal, never a gate.
- **`SessionStart`** re-injects the dispatcher after a compaction
  (`source: "compact"`), which is the one point where a turn can run without a
  fresh `UserPromptSubmit`.

**Turning the verifier off.** Put `locus: skip` anywhere in your prompt to skip
the check for that turn, or set `LOCUS_VERIFY=off` to disable it entirely. The
phrase is only honoured in *your* prompt, never in the model's reply — otherwise
a model could switch off its own check. The hook also blocks at most once per
turn (it honours `stop_hook_active`), so a misclassification costs you one extra
turn and can never wedge a session.

**The activation log.** Every turn appends a `turn` record — prompt id,
classification, whether the skill fired, whether the hook blocked. A turn that
was blocked appends a second `recovery` record once the model continues, so
"failed" and "failed then recovered" are distinguishable rather than both
reading as failure:

```jsonl
{"ts":"…","prompt_id":"c633b02f…","event":"turn","classification":"non-trivial","skill_fired":false,"blocked":true,"outcome":"blocked","reason":"…"}
{"ts":"…","prompt_id":"c633b02f…","event":"recovery","classification":"non-trivial","skill_fired":true,"blocked":false,"outcome":"recovered","reason":null}
```

`outcome` is one of `passed`, `escaped`, `blocked`, `recovered`, `unrecovered`.
The two records join on `prompt_id`. The turn record is written immediately
rather than held until the recovery, because the recovery Stop does not always
arrive — an aborted turn would otherwise vanish from the log entirely.

The block rate in that file *is* the activation-failure rate. It cannot tell you
whether the Algorithm helps; it can tell you whether the Algorithm **runs when
it should**, which previously could not be measured at all. It lands in your
configured data directory, or the plugin's own data directory if you have not
set one; `LOCUS_ACTIVATION_LOG_DIR` overrides both.

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

Delegation lets Locus redirect work from your primary AI tool to a cheaper, out-of-process backend — keeping the orchestrator's context clean and costs down.

**How it works:** When delegation is enabled, Locus hooks intercept native agent/task tool calls (e.g., Claude Code's `Agent` or `Task` tools) and block them. The AI is told to run `locus delegate run` instead, which shells out to the configured backend (currently OpenCode) and returns a compact JSON result envelope. The raw exploration never enters the orchestrator's context window.

**Enabling delegation:**

Add the `delegation` section to `~/.locus/locus.yaml`:

```yaml
delegation:
  enabled: true
  defaults:
    opencode:
      research:
        model: openai/gpt-5.5
      code_exploration:
        model: openai/gpt-5.5
      general:
        model: openai/gpt-5.5
```

- `enabled: true` — activates the hook that blocks native agent delegation and redirects to `locus delegate run`. When `false` (the default), native platform delegation is allowed through unmodified.
- `defaults` — per-backend, per-task-kind model defaults. The outer key is the backend (`opencode`), the inner key is the task kind (`research`, `code_exploration`, `general`). The `model` field sets the provider/model identifier passed to the backend.

After changing `locus.yaml`, no rebuild or platform re-add is needed — the hooks read the config at runtime.

**Running a delegation manually:**

```sh
locus delegate run --backend opencode \
                   --task-kind research \
                   --dir /path/to/project \
                   --prompt "Research this topic" \
                   --output json
```

The `--model` flag overrides the config default for a single invocation. If neither `--model` nor a config default is set, Locus falls back to `openai/gpt-5.5`.

**Task kinds:**

| Kind | When to use |
|------|-------------|
| `research` | Web/docs research, comparison sweeps, "what's the state of X" |
| `code-exploration` | Read-only codebase mapping, file enumeration, architecture surveys |
| `general` | Everything else |

**Disabling delegation:**

Set `enabled: false` in `locus.yaml` (or remove the `delegation` section entirely). Native Agent/Task tools will pass through without interception.

**Prerequisites:** Delegation currently requires [OpenCode](https://opencode.ai) installed and configured with API keys for the target model provider. Other backends may be added in the future.

See `locus delegate --help` for full options, and `locus delegate ls` / `locus delegate prune` for managing delegation artifacts.

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

Releases are built automatically by GitHub Actions
([`.github/workflows/release.yml`](.github/workflows/release.yml)) whenever a
version tag (`v*`) is pushed. Each tag produces a GitHub Release with a
`.tar.gz` (+ `.sha256`) for every supported platform, named by Rust target
triple so that `locus upgrade` can find the right one.

- Targets: macOS (Apple Silicon + Intel), Linux (x86_64 + ARM64), Windows (x86_64)
- Built natively on each platform's own runner — no cross-compilation
- Archive format is `.tar.gz` on every platform for compatibility with `locus upgrade`

### Cutting a release

The version in `Cargo.toml` is the source of truth; the git tag must match it.
The helper script keeps them in sync in one step:

```sh
scripts/release.sh 0.2.0          # bump Cargo.toml, refresh Cargo.lock, commit, tag v0.2.0
# then push to trigger the build:
git push origin main && git push origin v0.2.0

# or do it all at once:
scripts/release.sh 0.2.0 --push
```

The workflow's `verify` job hard-fails if the pushed tag does not match the
`Cargo.toml` version, so a mismatched release can never ship.

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
