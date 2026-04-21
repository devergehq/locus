# Locus

**Agentic AI workflow execution framework.**

Locus is a platform-agnostic layer that sits between you and your AI coding tool of choice. It provides the Algorithm (a phased decomposition for structured AI execution), skills (composable, multi-mode capabilities), agents (specialised roles for delegation), and persistent memory — without being tied to any single AI platform.

Supported platforms:

- **Claude Code** — via `locus platform add claude-code`
- **OpenCode** — via `locus platform add opencode`

Locus is installed as a single Rust binary. Skills, agents, protocols, and the Algorithm specification live under `~/.locus/`. The adapter for each platform writes only the minimum files needed to bootstrap Locus into that platform's native integration points — never more.

---

## Installation

### From source

```
cargo install --path crates/locus-cli
```

### Prebuilt binaries

Download the latest release for your platform from the [releases page](https://github.com/devergehq/locus/releases). The shell installer (`install.sh`) places the `locus` binary in `~/.local/bin/` by default.

### PATH requirement

**`locus` must be on your `PATH`.** Platform adapters configure hooks that call `locus hook <event>` — if the binary isn't resolvable, hooks will silently fail.

After installation, confirm with:

```
which locus
```

If that prints nothing, add the install directory to your shell's `PATH`. For the shell installer default:

```
export PATH="$HOME/.local/bin:$PATH"
```

(Add the line to `~/.zshrc`, `~/.bashrc`, or your shell's equivalent so it persists.)

---

## Quick start

```
locus init
locus platform add claude-code   # or: locus platform add opencode
locus doctor
```

`locus init` scaffolds `~/.locus/` with the Algorithm, skills, agents, and protocols. `locus platform add <platform>` wires Locus into that platform's global config directory (e.g., `~/.claude/CLAUDE.md` + `~/.claude/settings.json` for Claude Code). `locus doctor` validates the installation.

Any pre-existing platform system prompt file (e.g., an existing `~/.claude/CLAUDE.md` or `~/.config/opencode/AGENTS.md`) is backed up to `<filename>.pre-locus` before being replaced. `settings.json` and `opencode.json` are **merged** — user settings and non-Locus hooks are preserved.

---

## What gets installed

After `locus init`:

```
~/.locus/
├── algorithm/          # Algorithm specification
├── skills/             # Composable skill definitions (SKILL.md per skill)
├── agents/             # Agent role definitions
├── protocols/          # Context management, degradation, memory schema
├── data/               # User data (memory, checkpoints, learnings)
└── locus.yaml          # Canonical configuration
```

After `locus platform add claude-code`:

- `~/.claude/CLAUDE.md` — Locus bootstrap with the Algorithm embedded
- `~/.claude/settings.json` — merged Locus hook entries (SessionStart, PreCompact, Stop, PreToolUse, PostToolUse, UserPromptSubmit, Notification)

After `locus platform add opencode`:

- `~/.config/opencode/AGENTS.md` — Locus bootstrap with the Algorithm embedded
- `~/.config/opencode/opencode.json` — merged `instructions` pointing at Locus

**Nothing is written to `~/.claude/skills/`, `~/.claude/agents/`, `.opencode/`, or any other platform subdirectory.** All Locus content stays in `~/.locus/`; the Algorithm loads skills and agents on demand via the platform's Read tool.

---

## Removal

Locus is non-destructive. To remove:

```
locus platform remove claude-code
rm -rf ~/.locus
```

If the adapter backed up an existing file, restore it:

```
mv ~/.claude/CLAUDE.md.pre-locus ~/.claude/CLAUDE.md
```

---

## Commands

| Command                         | Purpose                                                |
|---------------------------------|--------------------------------------------------------|
| `locus init`                    | Scaffold `~/.locus/` and detect installed platforms    |
| `locus platform list`           | Show supported platforms and detection status          |
| `locus platform add <name>`     | Install the adapter for a platform                     |
| `locus platform remove <name>`  | Remove the adapter from `locus.yaml`                   |
| `locus skill list`              | List available skills                                  |
| `locus skill info <id>`         | Show detail for a specific skill                       |
| `locus doctor`                  | Validate the installation                              |
| `locus status`                  | One-shot installation and session summary              |
| `locus sync`                    | Sync user data via git                                 |
| `locus upgrade`                 | Update Locus itself from GitHub releases               |
| `locus hook <event>`            | Platform hook handler — invoked by Claude Code etc.    |

---

## License

Apache-2.0. See `Cargo.toml` for authorship.
