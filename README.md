# Locus

> A structured workflow framework for AI coding tools. It sits between you and Claude Code
> (or OpenCode) and gives the model a method, a set of skills, and a memory that persists.

**Status:** Early. Core features work, but APIs and conventions may still shift.

---

## What it is

Locus is two things that work together:

- **A Claude Code plugin** — the skills, agents and hooks. It injects a short dispatcher next
  to every prompt, asks the model to classify the request, and checks at the end of the turn
  that a non-trivial request actually ran the Algorithm.
- **A `locus` binary** — a single Rust executable that every hook calls, plus the CLI for
  setup, agent composition, delegation and upgrades.

What you get from it:

1. **The Algorithm** — a 7-phase decomposition (OBSERVE → THINK → PLAN → BUILD → EXECUTE →
   VERIFY → LEARN) with verifiable criteria, loaded on demand as the `locus-algorithm` skill.
2. **Skills** — research, council, red-team, first-principles, review-craft and more,
   loaded on demand.
3. **Agents** — trait-composed roles (expertise × stance × approach), not fixed personas.
4. **Persistent memory** — PRDs, checkpoints and learnings in `~/.locus/data/`.

## What it isn't

- **Not an AI coding tool.** It does not generate code. It structures the workflow *around*
  your AI tool.
- **Not tied to one platform.** Claude Code is the primary target; an OpenCode adapter exists.
- **Not commercial software.** MIT licensed.

If you just want to chat with an AI and don't care about structured workflows, Locus adds no
value.

---

## Quick start (Claude Code)

Five steps, about two minutes. No clone, no Rust toolchain.

```sh
# 1. Install the binary (macOS Apple Silicon shown — other platforms below)
mkdir -p ~/.local/bin
curl -L https://github.com/devergehq/locus/releases/latest/download/locus-aarch64-apple-darwin.tar.gz | tar -xz -C ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc

# 2. Install the plugin
claude plugin marketplace add devergehq/locus
claude plugin install locus@locus

# 3. Create ~/.locus (agent traits, statusline script, config, data directory)
locus init

# 4. Give Claude Code the statusline and the ~/.locus permission rules
locus platform add claude-code

# 5. Check everything
locus doctor
```

Then start (or restart) Claude Code. The first reply to any request opens with
`**Classification: Trivial**` or `**Classification: Non-trivial**`. That line tells you
Locus is running.

**Why each step is there:**

| Step | Without it |
|---|---|
| Binary | Every hook is inert. Locus tells you so loudly, once per session, and never blocks you. |
| Plugin | Nothing loads. The plugin is what puts the skills, agents and hooks into Claude Code. |
| `locus init` | `locus agent compose` and the statusline have nothing to read. |
| `platform add` | You get a permission prompt each time the Algorithm writes a PRD or checkpoint, and no statusline. A plugin cannot grant permissions or set a statusline, so the binary writes those two `settings.json` fields. It writes nothing else. |

The `claude` CLI is only needed for step 2. Inside a session, `/plugin` does the same job.

`locus` must be on the `PATH` of whatever launches `claude` — your terminal, tmux, Herder,
an IDE. If the hooks can't find it, the first message of every session says so.

---

## Installation

### The binary

Every tagged release publishes prebuilt binaries on the
[Releases page](https://github.com/devergehq/locus/releases):

| Platform | Architecture | Asset |
|----------|--------------|-------|
| macOS | Apple Silicon | `locus-aarch64-apple-darwin.tar.gz` |
| macOS | Intel | `locus-x86_64-apple-darwin.tar.gz` |
| Linux | x86_64 | `locus-x86_64-unknown-linux-gnu.tar.gz` |
| Linux | ARM64 | `locus-aarch64-unknown-linux-gnu.tar.gz` |
| Windows | x86_64 | `locus-x86_64-pc-windows-msvc.tar.gz` |

Each archive has a matching `.sha256`. Extract the binary to any directory on your `PATH`.
On Windows, `tar -xzf` works in PowerShell; put `locus.exe` on your `PATH`.

Use `curl` rather than a browser on macOS. A browser download is quarantined by Gatekeeper,
and the binary is not notarised. If you did use a browser:
`xattr -d com.apple.quarantine ~/.local/bin/locus`.

**Staying up to date:**

```sh
locus upgrade          # fetch and install the latest release in place
locus upgrade --check  # just report whether a newer version exists
claude plugin update locus@locus   # the plugin updates separately
```

The binary and the plugin are released together under one version number, so update both.
`locus doctor` warns when more than one `locus` is on your `PATH`, because the hooks only
run the first one.

### The plugin

The plugin comes from Locus's own marketplace. The repository is the marketplace —
`.claude-plugin/marketplace.json` — so it is not listed in Anthropic's plugin directory, and
you don't need to wait for anything to be published there.

```sh
claude plugin marketplace add devergehq/locus
claude plugin install locus@locus
```

```sh
claude plugin disable locus      # keep it installed, stop loading it
claude plugin uninstall locus    # remove it entirely
```

The plugin carries the skills, agents and hooks. It does **not** carry the binary, which is
per-platform. Install the binary separately (above).

### From source (contributors)

Requires [Rust](https://rustup.rs/).

```sh
git clone https://github.com/devergehq/locus.git
cd locus
cargo install --path crates/locus-cli   # -> ~/.cargo/bin/locus
```

<details>
<summary>Loading the plugin from a working tree</summary>

`--plugin-dir` loads a plugin for one invocation, for development:

```sh
./scripts/build-plugin.sh            # assemble dist/plugin/
claude --plugin-dir dist/plugin      # load it for one session
```

To exercise the real marketplace path against uncommitted work, point `marketplace add` at
the repo root. `.claude-plugin/marketplace.json` sources the plugin from `./`, so the same
manifest serves a local path and a GitHub clone:

```sh
claude plugin marketplace add /path/to/locus
claude plugin install locus@locus
```

</details>

---

## Running without Allele

Locus was built alongside Allele, which runs each
delegated task as a real, visible Claude Code session with its own workspace and branch.
**Allele is optional.** A plain Claude Code session works fine — in a terminal, tmux,
Herder or an IDE. The table shows what changes without it:

| Feature | Claude Code only | + OpenCode | + Allele |
|---|---|---|---|
| Classification, Algorithm, Stop check | ✅ | ✅ | ✅ |
| Skills (research, council, red-team, review-craft, …) | ✅ | ✅ | ✅ |
| `locus agent compose` | ✅ | ✅ | ✅ |
| Memory, PRDs, checkpoints | ✅ | ✅ | ✅ |
| Delegating a task to another agent | native subagent | `locus delegate run`, read-only | real session |
| `locus delegate run` | ❌ needs OpenCode | ✅ | ✅ |
| The Dispatcher (Linear/GitHub watcher) | ❌ | ❌ | ✅ |

With Claude Code only, delegation falls through to Claude Code's own `Agent` tool. The hook
allows it, and the model is told to say plainly that the work is running in a hidden
subagent with no branch of its own. The session notice says this is a supported
setup, and the model only mentions it when it actually delegates.

`locus delegate run` has one backend, OpenCode. It needs both the `opencode` binary and its
credentials. Without them it does not run.

The Dispatcher's whole job is turning Linear tickets and review requests into Allele
sessions. Without Allele it has nowhere to send them.

### Registering Allele, if you use it

Locus **detects** Allele; it does not bundle it. Register it once, at user scope:

```sh
claude mcp add allele --scope user -- /Applications/Allele.app/Contents/MacOS/Allele --mcp-serve
```

Point it at a **stable** path. A registration into `target/release/` works until the next
`cargo clean`, and then delegation dies silently.

---

## How the plugin works

| | Plugin |
|---|---|
| Algorithm | `locus-algorithm` skill, ~110 tokens always-on |
| Classification | injected next to **every** prompt, verified at turn end |
| Hooks | registered by the plugin, removed when you remove it |

All six hooks are implemented in the `locus` binary and run through one wrapper,
`hooks/via-locus-binary.sh`. The wrapper exists for one job the binary can't do itself:
noticing that the binary is missing.

- **`UserPromptSubmit`** injects the dispatcher (`crates/locus-cli/src/commands/dispatcher.txt`,
  under 1 KB) as `additionalContext`. Compliance decays with distance, so injecting it on
  every turn keeps the instruction close instead of relying on it staying salient thirty
  thousand tokens later.
- **`Stop`** checks that a turn which classified itself non-trivial actually invoked the
  skill. If not, it blocks **once** and says what was missed. It deliberately does *not*
  block on a missing classification line. The line is nearly free to emit and the skill
  invocation is the expensive behaviour, so gating on the line would teach the model to
  produce only the cheap half.
- **`SessionStart`** states which delegation vehicles are available, and re-injects the
  dispatcher after a compaction.
- **`PreToolUse`** routes native agent delegation to the vehicle that is actually reachable
  — see [Delegation vehicles](#delegation-vehicles). It only denies while there is
  somewhere better to send you.
- **`PostToolUse`** repairs PRD frontmatter after `sed`/`perl -i` edits.
- **`PreCompact`** writes an emergency checkpoint so compaction cannot lose state.

**If the binary is missing, Locus says so** — once per session, never blocking.
`LOCUS_HOOKS=off` stays completely silent, because that is a deliberate choice rather than
an accident.

**Turning the verifier off.** Put `locus: skip` anywhere in your prompt to skip the check
for that turn, or set `LOCUS_VERIFY=off` to disable it entirely. The phrase is only honoured
in *your* prompt, never in the model's reply, so a model can't switch off its own check. The
hook blocks at most once per turn, so a misclassification costs one extra turn and can never
wedge a session.

**The activation log.** Every turn appends a `turn` record — prompt id, classification,
whether the skill fired, whether the hook blocked. If the hook blocked, a `recovery` record
follows once the model continues, so "failed" and "failed then recovered" read differently:

```jsonl
{"ts":"…","prompt_id":"c633b02f…","event":"turn","classification":"non-trivial","skill_fired":false,"blocked":true,"outcome":"blocked","reason":"…"}
{"ts":"…","prompt_id":"c633b02f…","event":"recovery","classification":"non-trivial","skill_fired":true,"blocked":false,"outcome":"recovered","reason":null}
```

`outcome` is one of `passed`, `escaped`, `blocked`, `recovered`, `unrecovered`. The two
records join on `prompt_id`. The block rate in that file *is* the activation-failure rate:
it can't tell you whether the Algorithm helps, but it can tell you whether it **runs when it
should**. It lands in your configured data directory, or the plugin's own if none is set;
`LOCUS_ACTIVATION_LOG_DIR` overrides both.

### Delegation vehicles

Work leaves an orchestrator session through a **vehicle**, and there are four in
preference order. The preference is about observability: a real Allele session is
visible in the sidebar, addressable and interruptible, and a subagent is none of
those things.

| Tier | Vehicle | When |
|---|---|---|
| 1 | `allele_sessions_create` | The Allele app is reachable. The happy path. |
| 2 | `locus delegate run --backend opencode` | Allele unavailable. Read-only, no workspace, no branch. |
| 3 | native `Task` / `Agent` | Both above unavailable. Permitted, with the degradation stated. |
| 4 | inline | The work never warranted delegation in the first place. |

`SessionStart` states which of these are available, once per session.
`PreToolUse` denies a native subagent **only while a higher-priority vehicle is
actually reachable**, and names the one it is routing you to. When neither is
reachable it does not deny — denying with nowhere to send you is a dead end, and
that dead end is the reason this is a table rather than a prohibition.

Reachability is a `connect(2)` on `~/.allele/control.sock`, not a check that the
file is there. A socket file outlives the process that created it, so a crashed
app would otherwise read as healthy right up until the first call failed.
`LOCUS_ALLELE_SOCKET` overrides the path.

One thing the hook cannot see: whether *your session* has the `allele_*` tools.
It probes the machine, and a session started before the app — or one whose MCP
registration failed — has no Allele tools while the socket is perfectly healthy.
When you find yourself on the wrong side of that disagreement, say so and
re-issue the call with the description *starting with* `locus:no-allele` and your
reason after it. It must lead the field — the marker is documented here and in the
Algorithm spec, so a mention anywhere else is a quotation, not an assertion. That
releases the denial and records it, so the chain always terminates.

Degraded delegations append a line to `delegation-YYYY-MM.jsonl` next to the
activation log, so "how often did this actually happen, and was Allele up at the
time?" has an answer rather than an anecdote.

---

## Platform adapters

Locus connects to your AI coding tool via a **platform adapter**. Adapters are minimal and non-destructive:

- **Claude Code** — merges two fields into `~/.claude/settings.json`: `statusLine` and the
  `~/.locus` permission rules. The plugin supplies everything else; no `CLAUDE.md` is
  written and no hooks are registered here.
- **OpenCode** — writes to `~/.config/opencode/AGENTS.md` and merges `~/.config/opencode/opencode.json`

### Adding an adapter

```sh
locus platform add claude-code
```

Settings that Locus doesn't own are left alone, and re-running is safe.

### Removing an adapter

```sh
locus platform remove claude-code
```

This removes the Locus entries from the adapter's config. For Claude Code it also clears
what older Locus versions wrote: a generated `~/.claude/CLAUDE.md` and `locus hook` entries
in `settings.json`. If you installed before the plugin existed, run this once and
`locus doctor` will stop warning about duplicate hooks.

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

In Claude Code the Algorithm is the `locus-algorithm` skill. The dispatcher asks for it on every non-trivial turn, and the Stop hook checks that it ran. In OpenCode it is loaded through `opencode.json` instructions.

---

## What gets installed

After `locus init`:

```
~/.locus/
├── algorithm/          # Algorithm specification (v2.0.md)
├── skills/             # Skill definitions (SKILL.md per skill)
│   ├── council/
│   ├── creative/
│   ├── dispatcher/     # + dispatcher.py, config.example.json, workers/
│   ├── first-principles/
│   ├── iterative-depth/
│   ├── red-team/
│   ├── research/
│   ├── review-craft/   # + review_lint.py, lenses, house style, example
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

After `claude plugin install locus@locus`: skills, agents and hooks, loaded from the plugin
cache and removed with the plugin.

After `locus platform add claude-code`:

- `~/.claude/settings.json` — `statusLine` and `permissions.allow` for `~/.locus`, nothing else

After `locus platform add opencode`:

- `~/.config/opencode/AGENTS.md` — Locus bootstrap with Algorithm embedded
- `~/.config/opencode/opencode.json` — merged instructions

**Nothing is written to platform subdirectories like `~/.claude/skills/` or `.opencode/`.**

### The Dispatcher

`skills/dispatcher/` is a long-running session that watches Linear labels and GitHub review
requests and turns each into a real worker session. It is the one skill with per-user state, and
that state is deliberately kept out of the installed skill:

```
~/.locus/data/dispatcher/<slug>/
├── config.json         # Linear workspace + label ids, GitHub query, projects, limits
└── runtime/            # ledger, watch state, poll state, heartbeat
```

One instance per repo; several instances share one copy of the code. Create one with:

```bash
python3 ~/.locus/skills/dispatcher/dispatcher.py init --instance <slug> --team-key KEY
```

`init` is the only step that cannot be done by typing a config file out by hand: it creates the
`Agent` label group and its nine labels in the workspace you name and writes the ids it gets
back. It matches labels by name, so re-running it against a workspace that already has them
creates nothing. `--dry-run` prints what it would do and writes nothing.

Its review material lives in `skills/review-craft/`, which is a skill in its own right: five
callers inside the dispatcher already shared it, and it is useful on its own to anyone reviewing
a PR by hand.

---

## Removal

Locus is non-destructive:

```sh
claude plugin uninstall locus       # skills, agents, hooks
locus platform remove claude-code   # statusline + permission rules
locus platform remove opencode      # if you added it
rm -rf ~/.locus                     # all Locus data — memory and learnings included
rm ~/.local/bin/locus               # the binary
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
- Built on each platform's own runner, except `x86_64-apple-darwin`, which is
  cross-compiled from the Apple Silicon runner to avoid the scarce macos-13
  Intel pool. Release builds resolve the toolchain from `rust-toolchain.toml`
  (`rustup show`), then `rustup target add` attaches the target to *that*
  toolchain — targets are installed per toolchain, so adding it to a separately
  installed `stable` would leave the pinned one with no std for the one target
  that is genuinely cross-compiled
- Archive format is `.tar.gz` on every platform for compatibility with `locus upgrade`

### Cutting a release

The version in `Cargo.toml` is the source of truth; the git tag must match it.
The helper script keeps them in sync in one step:

The helper script runs in **two phases**, because `master` is protected and a
squash merge rewrites the commit — a tag cut before the merge would point at a
commit that never reaches `master`, and the published binaries would be built
from something that is not the release.

```sh
# Phase 1 — prepare the bump on a branch, open a PR, merge it.
scripts/release.sh 0.3.0 --push

# Phase 2 — tag the commit that actually landed, which triggers the build.
scripts/release.sh --tag 0.3.0 --push
```

Phase 2 re-reads `Cargo.toml` from `origin/master` and refuses to tag unless it
already carries the version being tagged, so the tag and the version it claims
cannot drift apart. The workflow's `verify` job checks the same thing again from
the other side, and hard-fails if the pushed tag does not match.

Every target builds with `--locked`, so the bump commit must carry a refreshed
`Cargo.lock`. Phase 1 does that for you; a stale lockfile fails all five builds,
not just one.

Update `CHANGELOG.md` in the same PR as the bump — its dated `[x.y.z]` heading
is what the release notes are written from.

The release assets are also what make the **plugin** functional: the plugin
carries skills, agents and hooks but never the per-platform `locus` binary, so
until a release exists carrying it, an installed plugin can only report that the
binary is missing.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the short version:

1. Open an issue first for anything non-trivial.
2. Run `cargo check`, `cargo test`, and `cargo fmt`.
3. Submit a PR with a clear description.

Response times are side-project pace (days to weeks). If you need faster, please fork.

### The PR description check

Pull requests here are checked against the `review-craft` house style by
[`.github/actions/pr-lint`](.github/actions/pr-lint/README.md) — the character budget for the
diff, headings, template debris, words that rot in a commit message, and whether the comment
the body's working notes link to exists. It runs when a pull request is marked ready, on a push
to one that is ready, on a description edit, and on a new comment — the last two because they
change the thing being checked without producing a commit. **A draft is not linted**, for the
same reason a draft runs no tests: the description of a pull request nobody can merge yet is
still being written. It can also be started by hand from the Actions tab against a pull request
number.

The action is reusable. **Another repository turns the same check on by copying one snippet**,
pinned to a commit SHA — the snippet, the inputs and the permissions it needs are in
[the action's README](.github/actions/pr-lint/README.md). It needs no `actions/checkout`: the
description is read over the API, never from the runner.

To run the same check by hand before opening a pull request:

```bash
python3 skills/review-craft/pr_lint.py --repo devergehq/locus --pr <n>
```

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
