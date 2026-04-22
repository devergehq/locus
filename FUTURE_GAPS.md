# Future Gaps

Known missing capabilities that have been deliberately deferred. Each entry
describes what the capability is, why it matters, how it should work, and
what the design intent is — so nothing is lost between now and when we pick
it up.

This file is the registry. Do not delete entries when work is picked up —
mark them as implemented and move details into the relevant crate's docs.

---

## G-1: `locus-index` — Rust-native project indexing

**Status:** Crate scaffolded (`crates/locus-index/`) but implementation is a
stub (single doc comment in `src/lib.rs`). Deferred until after the Claude
Code cutover is stable.

### What it is

Semantic code indexing for project codebases. Indexes source files using
AST-based chunking (tree-sitter) and vector embeddings. Supports hybrid
search — cosine similarity over semantic vectors plus TF-IDF keyword
matching, merged via Reciprocal Rank Fusion (RRF).

This replaces PAI's `ProjectIndex.ts` TypeScript tool with a Rust-native
implementation, keeping Locus single-binary.

### Why it matters

The Algorithm's OBSERVE phase explicitly queries `.code-index/` when it
exists (see `algorithm/v1.1.md`). Without a working indexer, OBSERVE falls
back to targeted Grep/Glob — functional, but slower and less precise for
large codebases. The indexer's value is pre-digested context: "show me the
code related to X" returns ranked chunks in milliseconds instead of taking
the agent through 10 searches.

The PAI version (TypeScript + Ollama `qwen3-embedding:4b`) has been
valuable in practice. We want the same capability, native to Locus.

### How it should work

1. **Walk** the project tree, skipping `.gitignore`, `.vectorignore`, and
   built-in exclusions (`node_modules/`, `vendor/`, `.git/`, `dist/`,
   `build/`, binaries, lock files, `.env` files).
2. **Chunk** each source file using tree-sitter AST parsing — split at
   function and class boundaries, preserve context headers.
3. **Embed** chunks via a local embedding service. Default: Ollama with
   `qwen3-embedding:4b` (1024-d vectors, truncated from native 2560).
4. **Store** the index at `{project}/.code-index/index.json` (or SQLite —
   benchmark both). Per-project, version-controllable.
5. **Query** with hybrid search — cosine similarity (semantic) + TF-IDF
   (keyword) merged via RRF. Return top-N with file path, line range,
   score, and snippet.
6. **Incremental builds** — only re-embed files that changed since last
   build (content-hash comparison).

### Planned CLI surface

```
locus index build              # incremental — default
locus index rebuild            # delete and re-embed everything
locus index query "text" [--top N]
locus index status             # files indexed, chunks, size, languages, last update
locus index progress           # progress bar for long builds
```

The Algorithm's OBSERVE phase calls `locus index query` when the
`.code-index/` directory exists.

### Design decisions captured so far

- **Single-binary principle:** no Python, no Node, no Bun. The embedding
  dependency is Ollama over HTTP — that is the only external runtime.
- **Fallback to keyword-only search when Ollama is unavailable.** The
  indexer must degrade gracefully — hybrid to TF-IDF-only, never silent
  failure.
- **Crate location:** `crates/locus-index` (already scaffolded).
- **Key Rust deps expected:** `tree-sitter` (+ grammar crates for major
  languages), `reqwest` or `ureq` for Ollama HTTP, `rusqlite` if SQLite
  wins benchmark, `ignore` (gitignore walker).
- **Not in scope:** cross-project indexing, cloud embeddings, web UI.
  Local, per-project, minimal.

### Estimated effort when picked up

1-2 weeks of focused work. The tree-sitter integration and hybrid search
are the substantive parts; Ollama HTTP and file walking are commodity.

---

## G-2: `create-skill` utility (internal meta-skill)

**Status:** Not ported. Reference: PAI `Packs/Utilities/src/CreateSkill/`.

### What it is

Internal tool for scaffolding new Locus skills with the correct directory
structure, SKILL.md frontmatter, workflows directory, and tests. Ensures
new skills follow the Locus convention — not left to memory or copy-paste
drift.

### Why it matters

As Locus gains skills over time, ad-hoc authoring diverges from
convention. A `locus skill create <name>` subcommand produces a correct
skeleton every time — faster for the author and consistent for the
framework.

This is an **internal consistency tool**, not a user-facing product
feature. The user should rarely run it; contributors should always use it
when adding a skill.

### How it should work

```
locus skill create <slug> [--tags tag1,tag2] [--requires delegation,inference]
```

Emits:
- `skills/<slug>/SKILL.md` with valid frontmatter, placeholder sections
- `skills/<slug>/Workflows/` directory (empty)
- A TODO file enumerating what the author still needs to fill in

Validates the slug is kebab-case, doesn't collide with existing skills,
and the `tags`/`requires` fields are recognised by `locus-core`.

### Design intent

- Validation by construction — the tool cannot produce an invalid skill.
- Idempotent — running twice does not corrupt an existing skill; it
  either declines (skill exists) or extends (adds missing files only).
- Complements `locus doctor` — doctor checks; creator prevents.

---

## G-3: `create-cli` utility (internal scaffolding tool)

**Status:** Not ported. Reference: PAI `Packs/Utilities/src/CreateCLI/`.

### What it is

Internal scaffolding tool for adding a new subcommand to the Locus CLI
with correct argument parsing, error handling, output formatting, and
test structure. Produces the boilerplate in `crates/locus-cli/src/commands/`
following the existing pattern (`commands/hook.rs`, `commands/platform.rs`,
etc.).

### Why it matters

Every time a new CLI subcommand is added, the author has to remember to:
- Add the subcommand enum variant in `main.rs`
- Create the `commands/<name>.rs` file with the right imports
- Register it in `commands/mod.rs`
- Thread error handling through `LocusError`
- Follow `output::success` / `output::info` / `output::error` conventions
- Add tests in the right location

A scaffolding tool removes this memory tax and keeps subcommands
consistent.

### How it should work

```
locus dev cli-add <name> [--args "arg1,arg2"] [--description "..."]
```

Emits the module file, updates `main.rs` and `commands/mod.rs`, and
generates a smoke test. Formats via `cargo fmt`.

### Design intent

- Internal developer tool, gated behind a `dev` subcommand namespace so it
  doesn't pollute the user-facing CLI.
- Opinionated — enforces the existing convention rather than allowing
  variation.
- Alternative considered: cargo-generate template. Rejected because
  in-tree scaffolding is more discoverable and can read existing code to
  stay consistent.

---

## G-4: `evals` skill (prompt / agent evaluation framework)

**Status:** Not ported. Reference: PAI `Packs/Utilities/src/Evals/`.

### What it is

Framework for systematically evaluating prompt and agent quality against
benchmarks. Supports scorer types (LLM-as-judge, heuristic, regex), eval
suites, and comparison mode (A vs B prompts, model X vs model Y).

### Why it matters

Without an evals skill, changes to agent prompts or traits are evaluated
by vibes. An eval suite gives Locus a reproducible way to verify that
changes improve — or at minimum don't regress — measured behaviour on
real tasks.

Particularly important for: trait vocabulary changes (does adding a new
stance improve debate quality?), agent archetype prompt changes (does
the rewritten Architect produce better architectural reasoning?), and
research workflow changes.

### How it should work

Directory layout:
```
evals/
├── suites/              # Eval suite definitions (YAML)
├── graders/             # Scorer implementations
├── data/                # Fixtures (inputs, expected outputs)
└── runs/                # Run outputs (JSON, timestamped)
```

CLI:
```
locus eval run <suite>            # Run a suite
locus eval compare <run-a> <run-b>  # Diff two runs
locus eval view <run>              # Summary of a run
```

### Design intent

- Provider-agnostic at the data level — a suite definition shouldn't
  hard-code which LLM runs it.
- Cheap to run locally; also scriptable in CI.
- Deferred because the value only unlocks once Locus has enough stable
  skills to regression-test.

---

## G-5: `prompting` skill (meta-prompting patterns)

**Status:** Not ported. Reference: PAI `Packs/Utilities/src/Prompting/`.

### What it is

Library of meta-prompting patterns — prompt shapes that reliably improve
output quality (chain-of-thought, self-consistency, contrastive
decoding, few-shot with diverse examples, etc.). Documents when each
pattern helps and when it adds noise.

### Why it matters

The Algorithm invokes skills; skills produce prompts; prompts benefit
from known-good structural patterns. A meta-prompting skill gives the
Algorithm a vocabulary for "what shape should this prompt have" rather
than reinventing it each time.

Should be evidence-linked — each pattern cites the paper or benchmark
that justifies it.

### How it should work

Skill with patterns as sub-files:
```
skills/prompting/
├── SKILL.md
├── Patterns/
│   ├── chain-of-thought.md
│   ├── self-consistency.md
│   ├── contrastive.md
│   ├── few-shot-diverse.md
│   └── ...
└── Workflows/
    ├── SelectPattern.md     # "I have this task, which pattern helps?"
    └── ApplyPattern.md      # "Wrap this prompt in pattern X"
```

### Design intent

- Evidence-anchored: every pattern has a citation and a measured effect
  size where available.
- Narrow: only patterns that show robust benefits across reasoning
  benchmarks (excludes persona-character prompts per the Research finding
  on Locus's persona design).
- Deferred because the Trait system already covers the stance dimension,
  which overlaps with what a lightweight prompting skill would start with.

---

## G-6: `browser` skill (web browsing / scraping)

**Status:** Not ported. Reference: PAI `Packs/Utilities/src/Browser/`.

### What it is

Skill that wraps the platform's native browser tools (Claude Code's
browser, Playwright via MCP, etc.) with Locus workflows for common
scraping, form-filling, screenshot, and page-extraction tasks.

### Why it matters

Research workflows (WebScraping, YoutubeExtraction, Retrieve) implicitly
depend on a browsing capability. Right now each workflow describes what
to do assuming the browser is accessible; a dedicated `browser` skill
would centralise the workflows.

### Why deferred

Claude Code already provides browser tools natively, and OpenCode has
its own equivalents. A Locus `browser` skill adds a thin abstraction on
top. Not urgent — research workflows reference the platform's browser
tools directly.

### Design intent when picked up

- Platform-neutral workflow layer — same skill text works whether the
  underlying browser is Playwright, Claude's native browser, or
  something else.
- Graceful degradation — if no browser is available, skills that would
  use it should report `Unavailable` via the Degradation Protocol.

---

## G-7: Deep deferrals (not stubbed, captured for awareness)

These are PAI packs the user explicitly excluded; they are captured here
only to prevent future re-discovery of "what happened to X":

- **Telos** — Life OS, goals, projects dashboard. Not in Locus scope.
  Locus is an agentic workflow framework, not a life-OS.
- **USMetrics** — FRED / EIA / Treasury / BLS economic data feed.
  User-specific; not a general Locus capability.
- **Scraping** (Apify / BrightData) — Vendor-specific scraping actors.
  Replaced by the generic `research/Workflows/WebScraping.md`.
- **Investigation** (OSINT, PrivateInvestigator) — Specialised,
  explicitly out of scope for Locus v1.
- **Billing** — Time tracking, PAI-specific.
- **ContextSearch** — Redundant with `locus-index` once that is built
  (G-1). The PAI slash-command form will not be ported.
- **Utilities / Fabric** — 240+ Daniel Miessler patterns. Evaluated;
  most patterns are out of scope for the domains Locus operates in.
  Not ported. Repo remains a reference.
- **Utilities / Aphorisms, AudioEditor, Cloudflare, PAIUpgrade** —
  PAI-specific or user-specific.
- **Agents / ComposeAgent.ts and related TypeScript tools** —
  Reimplemented in Rust as `locus agent compose`.
- **Thinking / WorldThreatModelHarness** — Skipped per user direction.
- **Remotion (video generation)** — Out of scope; user does not use.

---

## Entry template (for future additions)

When capturing a new gap, use this structure:

```markdown
## G-N: <Short name>

**Status:** Not ported / Deferred / Stubbed.

### What it is
<1-2 paragraphs — what is this capability?>

### Why it matters
<What value does it add? What breaks without it?>

### How it should work
<Design sketch — directory layout, CLI surface, key dependencies,
algorithm sketch. Enough that a future implementer does not have to
re-derive the design.>

### Design decisions captured so far
<Any choices already made that constrain the implementation.>

### Estimated effort when picked up
<Rough order of magnitude — hours, days, weeks.>
```
