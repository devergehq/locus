//! Claude Code configuration generation.
//!
//! Generates the minimal configuration needed for Claude Code to use Locus:
//! - A directive `~/.claude/CLAUDE.md` that embeds the Algorithm and points at
//!   Locus content under `~/.locus/`.
//! - `hooks` entries in `~/.claude/settings.json` that call `locus hook <event>`
//!   for SessionStart, PreCompact, PostToolUse, Stop, UserPromptSubmit,
//!   PreToolUse, and Notification.
//!
//! Zero files are written to `~/.claude/skills/` or `~/.claude/agents/`. The
//! Algorithm is the sole orchestration layer — skills and agents stay in
//! `~/.locus/` and are loaded by the Algorithm via the Read tool.

use std::path::{Path, PathBuf};

use locus_core::error::LocusError;
use locus_core::platform::Platform;

/// The global Claude Code config directory (`~/.claude/`).
fn global_config_dir() -> Result<PathBuf, LocusError> {
    dirs::home_dir()
        .map(|h| h.join(".claude"))
        .ok_or_else(|| LocusError::Adapter {
            platform: Platform::ClaudeCode,
            message: "Could not determine home directory".into(),
        })
}

/// Result of writing CLAUDE.md.
pub struct ClaudeMdWrite {
    /// Path to the CLAUDE.md file that was written.
    pub path: PathBuf,
    /// Whether a pre-existing non-Locus CLAUDE.md was backed up to `.pre-locus`.
    pub backed_up: bool,
}

/// Generate the CLAUDE.md file with the Algorithm inlined.
///
/// Placed at `~/.claude/CLAUDE.md`, this applies to all Claude Code sessions
/// globally. The Algorithm is embedded directly so it is guaranteed to be in
/// context without relying on any path resolution or auto-loading by the
/// platform.
///
/// Source of truth for the Algorithm remains `~/.locus/algorithm/v1.1.md`.
/// Regenerate with `locus platform add claude-code`.
/// Enumerate the trait vocabulary from `{locus_home}/agents/traits.yaml`.
///
/// `locus agent compose` already validates against this file at runtime, so a
/// new trait *works* the moment it is added. It was simply never *advertised* —
/// the directive carried a hand-written copy of the vocabulary. That is the same
/// failure as the `delegation` skill: fully functional and unknown to every
/// session. Enumerating removes the second source of truth.
///
/// Worth knowing if this ever regresses: the symptom is not an error. An
/// unadvertised trait presents as *"nobody ever uses that trait"*, never as
/// *"that trait is broken"* — it validates and composes correctly the moment
/// anyone names it. Someone investigating will go looking for a bug and find
/// none, because there isn't one; the defect is an absence in the directive.
///
/// Axes are `BTreeMap`s, so ordering is already deterministic.
fn enumerate_traits(locus_home: &Path) -> String {
    let path = locus_home.join("agents").join("traits.yaml");

    let Ok(traits) = locus_core::agents::Traits::from_file(&path) else {
        return "<!-- traits.yaml not found or unparseable. Run `locus init` to install. -->"
            .to_string();
    };

    let axis = |label: &str, m: &std::collections::BTreeMap<String, locus_core::agents::Trait>| {
        (!m.is_empty()).then(|| {
            format!(
                "- **{label}:** {}",
                m.keys().cloned().collect::<Vec<_>>().join(", ")
            )
        })
    };

    let rows: Vec<String> = [
        axis("Expertise", &traits.expertise),
        axis("Stance", &traits.stance),
        axis("Approach", &traits.approach),
    ]
    .into_iter()
    .flatten()
    .collect();

    if rows.is_empty() {
        return "<!-- No traits defined. -->".to_string();
    }
    rows.join("\n")
}

/// Enumerate `{locus_home}/skills/*/SKILL.md` into a comma-separated list.
///
/// Hardcoding this list is how `delegation` came to exist on disk while no
/// session was ever told about it: the skill installed correctly and the
/// directive never mentioned it. Enumeration removes the drift by construction.
fn enumerate_skills(locus_home: &Path) -> String {
    let dir = locus_home.join("skills");

    let Ok(entries) = std::fs::read_dir(&dir) else {
        return "<!-- No skills directory found. Run `locus init` to install. -->".to_string();
    };

    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("SKILL.md").is_file())
        .filter_map(|p| Some(p.file_name()?.to_str()?.to_string()))
        .collect();

    if names.is_empty() {
        return "<!-- No skills installed. -->".to_string();
    }

    names.sort();
    names.join(", ")
}

/// One-line summary for a protocol file, for the CLAUDE.md index.
///
/// Prefers a `description:` field in YAML frontmatter; falls back to the first
/// H1 heading. Both are optional — a protocol with neither is still indexed by
/// filename, because being listed is what makes it discoverable and that must
/// not depend on the author having known about this format.
fn protocol_summary(content: &str) -> Option<String> {
    if let Some(rest) = content.strip_prefix("---\n") {
        if let Some(end) = rest.find("\n---") {
            for line in rest[..end].lines() {
                if let Some(v) = line.strip_prefix("description:") {
                    let v = v.trim().trim_matches('"').trim_matches('\'').trim();
                    if !v.is_empty() {
                        return Some(v.to_string());
                    }
                }
            }
        }
    }

    content
        .lines()
        .find_map(|l| l.strip_prefix("# "))
        .map(|h| h.trim().to_string())
        .filter(|h| !h.is_empty())
}

/// Enumerate `{locus_home}/protocols/*.md` into a markdown index.
///
/// Enumerated rather than hardcoded deliberately. A hardcoded list requires the
/// author of a new protocol to know about and edit a Rust file in another crate,
/// and the failure when they do not is *silence* — the protocol simply never
/// loads. That is not hypothetical: the skills list in this same file drifted out
/// of sync with `{locus_home}/skills/` and nobody noticed.
///
/// A missing or unreadable directory degrades to a note rather than failing the
/// whole config generation, matching how a missing Algorithm is handled above.
fn enumerate_protocols(locus_home: &Path) -> String {
    let dir = locus_home.join("protocols");

    let Ok(entries) = std::fs::read_dir(&dir) else {
        return "<!-- No protocols directory found. Run `locus init` to install. -->".to_string();
    };

    let mut rows: Vec<(String, Option<String>)> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .filter_map(|p| {
            let name = p.file_name()?.to_str()?.to_string();
            let summary = std::fs::read_to_string(&p)
                .ok()
                .as_deref()
                .and_then(protocol_summary);
            Some((name, summary))
        })
        .collect();

    if rows.is_empty() {
        return "<!-- No protocols installed. -->".to_string();
    }

    // Sorted so regenerating without changing anything produces no diff.
    rows.sort_by(|a, b| a.0.cmp(&b.0));

    rows.into_iter()
        .map(|(name, summary)| match summary {
            Some(s) => format!("- `{name}` — {s}"),
            None => format!("- `{name}`"),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn generate_claude_md(locus_home: &Path) -> String {
    let home = locus_home.display();

    // Read the Algorithm from disk — falls back to a placeholder if it's not
    // yet installed, which is the only reasonable degraded mode.
    let algorithm_path = locus_home.join("algorithm").join("v1.1.md");
    let algorithm_content = std::fs::read_to_string(&algorithm_path)
        .unwrap_or_else(|_| "<!-- Algorithm not found. Run `locus init` to install. -->".into());

    let protocol_index = enumerate_protocols(locus_home);
    let skill_list = enumerate_skills(locus_home);
    let trait_list = enumerate_traits(locus_home);

    format!(
        r#"# Locus

This system uses the Locus agentic workflow framework.

Locus home: {home}

Read and follow the Algorithm at `{home}/algorithm/v1.1.md` for all non-trivial requests.
For trivial requests (single file, single action, no investigation needed), handle directly.

When the Algorithm calls for skills, read the relevant skill from `{home}/skills/<skill-id>/SKILL.md` via the Read tool.
When the Algorithm calls for agent delegation, read agent definitions from `{home}/agents/` via the Read tool, then delegate via `locus delegate run`.
Protocols are at `{home}/protocols/`. **Read one via the Read tool when its subject is in play** — do not load them all:

{protocols}

User data (learnings, research, work artifacts, checkpoints) is persisted to `{home}/data/`.

## Project Identity

When working in a project directory, Locus resolves the canonical project slug using:
1. `.locus-project` marker file (searched from `$PWD` up to `$HOME`)
2. `_registry.json` exact path match
3. `_registry.json` pattern match
4. Legacy fallback (unregistered project)

See `{home}/protocols/memory-schema.md` for full details.

## Mode Classification (MANDATORY)

Before responding to ANY user request, classify it:

- **Trivial** — single file, single action, one clear concept, no investigation required → handle directly without the Algorithm. Answer questions, rename variables, small edits. **Open every trivial response with `**Classification: Trivial**` — one line, before any other content.**
- **Non-trivial** — multiple steps, investigation, design decisions, complex changes, or anything that would benefit from ISC-tracked execution → ENTER THE ALGORITHM. **Open with `**Classification: Non-trivial**` before the OBSERVE phase output.**

A response without a classification line is a compliance failure — the user cannot tell Locus ran.

## Algorithm Execution (MANDATORY for non-trivial requests)

The Algorithm specification is inlined below. When entering the Algorithm, you MUST:

1. Follow the 7-phase structure: OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN.
2. Start with OBSERVE: reverse-engineer the request, determine effort level, generate atomic ISC criteria meeting the tier floor, select capabilities.
3. Produce structured, visible output at every phase transition — no silent execution.
4. Create a PRD at `{home}/data/memory/work/{{slug}}/PRD.md` to track criteria and progress.
5. Never skip phases — each feeds the next.
6. Checkpoint at every phase transition to `{home}/data/memory/state/`.
7. Persist learnings in LEARN to `{home}/data/memory/learning/session/{{YYYY-MM}}/`.

The Algorithm document defines effort levels (Minimal, Standard, Extended, Advanced, Deep, Comprehensive), numeric ISC floors per tier, time budgets, the Splitting Test for atomic criteria, the Phantom Capability Rule, and full phase specifications. Follow it exactly.

## Skill Invocation

Skills are NOT registered as native Claude Code skills — Locus deliberately keeps the Algorithm as the sole orchestration layer. When OBSERVE's capability selection identifies a skill, use the Read tool to load its SKILL.md from `{home}/skills/<skill-id>/SKILL.md`.

Available skills: {skills}.

## Delegation Guardrail

Any agent-style delegation MUST go through `locus delegate run`. Do not use platform-native Task/Agent subagents for research, code exploration, council/red-team work, or any other delegated agent work. Native subagents burn orchestrator context and bypass Locus's compact result envelope.

If `locus delegate run` is unavailable or failing, do not fall back to native Task/Agent delegation. Continue serially or ask the user how to proceed.

### Delegation Denial Compliance (CRITICAL)

When a hook denies a native Agent or Task tool call, the denial message contains the exact `locus delegate run` command to execute instead. You MUST execute that command immediately via Bash. Specifically:

- **Do NOT** fall back to doing the work yourself ("I'll just read the files directly", "Let me handle this in the current session")
- **Do NOT** say "since I can't delegate, I'll do it manually" — that defeats the entire purpose of delegation
- **Do** copy the `locus delegate run` command from the denial message and run it via Bash
- The denial means "use this other tool", not "give up on delegation"

This is the single most common compliance failure. If you catch yourself about to do delegated work inline after a denial, stop and run `locus delegate run` instead.

## Memory

Locus maintains its own project memory at `{home}/data/projects/`. When reading or writing memories:

- **Read from both**: check `{home}/data/projects/` (Locus canonical store) AND `~/.claude/projects/*/memory/` (Claude Code native). Locus is authoritative when they conflict.
- **Write to both**: Claude Code's native memory system is mirrored automatically by hooks, but always verify Locus has the memory too. If writing something important, write it to the Locus project directory directly.

## Agent Composition

Locus composes agent prompts from trait IDs. Use `locus agent compose` to build a trait-composed prompt, then pass it to `locus delegate run --prompt`.

**CLI reference — `locus agent compose`:**

| Flag | Required | Description |
|------|----------|-------------|
| `--traits <IDS>` | Yes | Comma-separated trait IDs (e.g. `"security,skeptical,thorough"`) |
| `--role <ROLE>` | No | Role statement prepended to prompt (`"You are <role>."`) |
| `--task <TASK>` | No | Task statement appended to prompt (`"Your task: <task>"`) |
| `--output <MODE>` | No | `prompt` (default, plain text) or `json` (structured object) |

**Available traits (by axis):**

{traits}

Pick 2-4 traits across axes. One expertise + one stance + one approach is the standard pattern.

**Compose-then-delegate workflow:**

```bash
# 1. Compose the agent prompt
PROMPT=$(locus agent compose \
  --traits "research,skeptical,systematic" \
  --role "Security researcher" \
  --task "Investigate auth token storage patterns in this codebase")

# 2. Delegate the composed agent
locus delegate run \
  --backend opencode \
  --model openai/gpt-5.6-sol \
  --task-kind code-exploration \
  --mode native \
  --dir . \
  --prompt "$PROMPT" \
  --output json
```

For parallel dispatch, issue multiple compose+delegate pairs as separate Bash tool calls in one assistant message.

## Locus Delegate

For bounded read-only work that would otherwise burn the orchestrator's context (large codebase exploration, lengthy research sweeps, doc digests), shell out to `locus delegate run --backend opencode` instead of doing the work in-session. Native subagents stay prohibited: they are other Claudes sharing the orchestrator budget, while Locus Delegate runs out-of-process and returns a compact JSON envelope so the raw exploration never enters this context.

**When to delegate:**
- Research with broad scope (multiple sources, comparison sweeps, "what's the state of X")
- Read-only codebase mapping in unfamiliar repos (>5 files to understand structure)
- Documentation or API surface enumeration where the answer is structured but voluminous
- Any task whose intermediate work matters less than its final summary

**When NOT to delegate:**
- Trivial lookups (one file, one grep) — the round-trip costs more than doing it
- Anything requiring writes, commits, or persistent state changes (delegation is read-only)
- Time-sensitive work in an interactive flow (delegation adds 30-90s latency)
- Tasks that depend on context already loaded in this session
- Anything that needs a tool the backend doesn't have (e.g. a specific MCP server)

**CLI reference — `locus delegate run`:**

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--backend <BACKEND>` | Yes | — | Backend to use (`opencode`) |
| `--model <MODEL>` | No | `openai/gpt-5.6-sol` | Provider-qualified model identifier |
| `--task-kind <KIND>` | Yes | — | `research`, `code-exploration`, or `general` |
| `--dir <DIR>` | Yes | — | Workspace directory for the delegated backend |
| `--prompt <PROMPT>` | Yes | — | Task prompt (or composed agent prompt from `locus agent compose`) |
| `--mode <MODE>` | No | `native` | `native` (no Algorithm) or `algorithmic` (loads Algorithm — rarely wanted) |
| `--output <MODE>` | No | `json` | `json` (machine-readable) or `human` (readable status) |
| `--context-file <PATH>` | No | — | Attach a file as context (repeatable for multiple files) |
| `--agent <NAME>` | No | — | Backend agent/profile name |
| `--timeout-seconds <N>` | No | `1200` | Maximum execution time (20 min default) |
| `--dry-run` | No | — | Print request JSON without invoking the backend |

Use `--task-kind code-exploration` for codebase mapping, `--task-kind research` for web/doc research, and `--task-kind general` for everything else. Use `--model openai/gpt-5.6-sol` for the standard delegate model.

**`--mode native` is the default and almost always what you want.** It runs the delegated session with no Locus orchestration scaffolding loaded — the delegated model just reads the prompt and produces the requested output, no `OBSERVE → THINK → PLAN` phases, no Mode Classification. Use `--mode algorithmic` *only* in the rare case the delegated session itself needs to orchestrate (you almost never want this; the orchestrator is *this* session, not the delegate).

**Result envelope:**

The command prints a single JSON object with these fields:
- `summary` — one-paragraph synthesis of the model's final answer
- `findings` — bulleted observations extracted from the answer
- `evidence` — concrete references the answer cited
- `risks` — caveats or limitations the model flagged
- `files_referenced` — paths the model read or named
- `raw_output_path` — JSONL artifact with the full event stream, for deep dives

Read `summary`, `findings`, and `files_referenced` straight into your reasoning. Only open `raw_output_path` if you need detail the envelope dropped.

## Platform Tools (Claude Code)

The following native tools are available in this Claude Code session:
- **read** — read files
- **edit** — modify files
- **bash** — execute shell commands
- **web_search** — open-ended web search
- **web_fetch** — retrieve content from URLs
- **task** — available, but prohibited for Locus delegation; use `locus delegate run`
- **glob** — find files by pattern
- **grep** — search file contents

Always prefer the native tool over shell equivalents (e.g., use `glob` instead of `find`,
use `grep` instead of `grep` in Bash). Use `web_search` for discovery and `web_fetch`
for verification of specific URLs.

---

{algorithm}
"#,
        home = home,
        algorithm = algorithm_content,
        protocols = protocol_index,
        skills = skill_list,
        traits = trait_list,
    )
}

/// Write CLAUDE.md to the global Claude Code config directory.
///
/// Backs up any existing non-Locus CLAUDE.md to `CLAUDE.md.pre-locus` before
/// overwriting. Returns both the path written and whether a backup occurred.
pub fn write_claude_md(locus_home: &Path) -> Result<ClaudeMdWrite, LocusError> {
    let config_dir = global_config_dir()?;
    std::fs::create_dir_all(&config_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create config dir: {}", e),
        path: config_dir.clone(),
    })?;

    let claude_md_path = config_dir.join("CLAUDE.md");

    let mut backed_up = false;
    if claude_md_path.exists() {
        let existing = std::fs::read_to_string(&claude_md_path).unwrap_or_default();
        if !existing.contains("# Locus") {
            let backup_path = config_dir.join("CLAUDE.md.pre-locus");
            std::fs::copy(&claude_md_path, &backup_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to backup CLAUDE.md: {}", e),
                path: backup_path,
            })?;
            backed_up = true;
        }
    }

    let content = generate_claude_md(locus_home);
    std::fs::write(&claude_md_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write CLAUDE.md: {}", e),
        path: claude_md_path.clone(),
    })?;

    Ok(ClaudeMdWrite {
        path: claude_md_path,
        backed_up,
    })
}

/// Merge Locus hook entries into `~/.claude/settings.json`.
///
/// Preserves all non-Locus hooks. Any hook entries whose command invokes the
/// `locus hook` CLI are replaced so the merge is idempotent across runs.
///
/// Writes hook entries for SessionStart, PreCompact, Stop, PreToolUse,
/// PostToolUse, UserPromptSubmit, and Notification. `locus` is assumed to be
/// on the user's PATH (documented in the README).
pub fn update_settings_json(locus_home: &Path) -> Result<PathBuf, LocusError> {
    let config_dir = global_config_dir()?;
    std::fs::create_dir_all(&config_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create config dir: {}", e),
        path: config_dir.clone(),
    })?;

    let settings_path = config_dir.join("settings.json");

    let mut settings: serde_json::Value = if settings_path.exists() {
        let content =
            std::fs::read_to_string(&settings_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to read settings.json: {}", e),
                path: settings_path.clone(),
            })?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    };

    merge_locus_hooks(&mut settings);
    merge_locus_statusline(&mut settings, locus_home);
    merge_locus_permissions(&mut settings, locus_home);

    let content = serde_json::to_string_pretty(&settings).map_err(|e| LocusError::Adapter {
        platform: Platform::ClaudeCode,
        message: format!("Failed to serialise settings.json: {}", e),
    })?;

    std::fs::write(&settings_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write settings.json: {}", e),
        path: settings_path.clone(),
    })?;

    Ok(settings_path)
}

/// The canonical Locus hook entries for Claude Code's `settings.json`.
///
/// Each tuple is (hook_name, matcher, command). Exposed so unit tests can
/// assert against the exact set without duplicating the list.
pub fn locus_hook_entries() -> &'static [(&'static str, Option<&'static str>, &'static str)] {
    &[
        ("SessionStart", None, "locus hook session-start"),
        ("PreCompact", None, "locus hook pre-compact"),
        ("Stop", None, "locus hook stop"),
        ("UserPromptSubmit", None, "locus hook user-prompt-submit"),
        ("PreToolUse", None, "locus hook pre-tool-use"),
        ("PostToolUse", None, "locus hook post-tool-use"),
        ("Notification", None, "locus hook notification"),
    ]
}

/// Merge Locus hook entries into a parsed settings.json value in place.
///
/// Preserves all non-Locus hooks and all non-Locus root keys. Any hook entry
/// whose command starts with `"locus hook "` is replaced so the merge is
/// idempotent across runs.
pub fn merge_locus_hooks(settings: &mut serde_json::Value) {
    if !settings.is_object() {
        *settings = serde_json::json!({});
    }

    {
        let root = settings.as_object_mut().expect("settings is object");
        if !root.get("hooks").map(|v| v.is_object()).unwrap_or(false) {
            root.insert("hooks".to_string(), serde_json::json!({}));
        }
    }

    let hooks = settings
        .get_mut("hooks")
        .and_then(|v| v.as_object_mut())
        .expect("hooks exists and is object");

    for (hook_name, matcher, command) in locus_hook_entries() {
        upsert_hook(hooks, hook_name, *matcher, command);
    }
}

/// Set the `statusLine` entry in settings.json to point at the Locus
/// statusline script. Only overwrites if the current entry is missing or
/// already a Locus statusline (identified by the `locus/scripts/statusline`
/// path fragment). Non-Locus statuslines are preserved so users who have
/// customised their own statusline don't lose it.
pub fn merge_locus_statusline(settings: &mut serde_json::Value, locus_home: &Path) {
    if !settings.is_object() {
        return;
    }
    let script = locus_home
        .join("scripts")
        .join("statusline.sh")
        .display()
        .to_string();

    let existing = settings.get("statusLine").cloned();
    let is_locus_owned = existing
        .as_ref()
        .and_then(|v| v.get("command"))
        .and_then(|v| v.as_str())
        .map(|s| s.contains("locus/scripts/statusline") || s.contains(".locus/scripts/statusline"))
        .unwrap_or(false);

    if existing.is_none() || is_locus_owned {
        settings.as_object_mut().unwrap().insert(
            "statusLine".to_string(),
            serde_json::json!({
                "type": "command",
                "command": script
            }),
        );
    }
}

/// The Locus-owned `permissions.allow` entries for Claude Code's `settings.json`.
///
/// Uses Claude Code's permission rule syntax:
/// - `Read(<path>/**)` — allows the Read tool on all files under `locus_home`.
/// - `Write(<path>/**)` — allows the Edit tool on all files under `locus_home/data`.
/// - `Bash(<cmd> <path>*)` — allows read-only shell commands on `locus_home` paths.
///
/// Read access is granted across the entire Locus home so skills, agents, and
/// protocols can be loaded on demand. Write access is limited to `data/` so
/// PRDs, checkpoints, and learnings can be persisted without prompting.
/// Exposed so unit tests can assert against the exact set.
pub fn locus_permission_entries(locus_path: &str) -> Vec<String> {
    vec![
        format!("Read({}/**)", locus_path),
        format!("Write({}/data/**)", locus_path),
        format!("Bash(cat {}*)", locus_path),
        format!("Bash(find {}*)", locus_path),
        format!("Bash(ls {}*)", locus_path),
        format!("Bash(head {}*)", locus_path),
        format!("Bash(tail {}*)", locus_path),
    ]
}

/// Merge Locus permission entries into a parsed settings.json value.
///
/// Adds `permissions.allow` entries for Read (whole `locus_home`), Write
/// (`locus_home/data/**` only), and common read-only Bash commands on
/// `locus_home`. Also adds `locus_home` to `additionalDirectories`.
/// Additionally allows Read and Write access to the allele home directory
/// so the AI can operate on allele workspaces without prompting.
///
/// The merge is idempotent: existing Locus-owned entries are replaced on each
/// run, non-Locus entries are preserved.
pub fn merge_locus_permissions(settings: &mut serde_json::Value, locus_home: &Path) {
    if !settings.is_object() {
        *settings = serde_json::json!({});
    }

    let locus_path = locus_home.display().to_string();
    let entries = locus_permission_entries(&locus_path);

    // Ensure permissions object exists.
    {
        let root = settings.as_object_mut().expect("settings is object");
        if !root
            .get("permissions")
            .map(|v| v.is_object())
            .unwrap_or(false)
        {
            root.insert("permissions".to_string(), serde_json::json!({}));
        }
    }

    let perms = settings
        .get_mut("permissions")
        .and_then(|v| v.as_object_mut())
        .expect("permissions exists and is object");

    // --- allow array ---
    if !perms.get("allow").map(|v| v.is_array()).unwrap_or(false) {
        perms.insert("allow".to_string(), serde_json::json!([]));
    }

    let allow = perms
        .get_mut("allow")
        .and_then(|v| v.as_array_mut())
        .expect("allow is array");

    // Remove any prior Locus-owned entries so the merge is idempotent.
    allow.retain(|entry| {
        let s = entry.as_str().unwrap_or("");
        !entries.iter().any(|e| e == s)
    });

    for entry in &entries {
        allow.push(serde_json::json!(entry));
    }

    // --- allele permissions ---
    if let Some(allele_home) = dirs::home_dir().map(|h| h.join(".allele")) {
        let allele_path = allele_home.display().to_string();
        let allele_entries = vec![
            format!("Read({}/**)", allele_path),
            format!("Write({}/**)", allele_path),
            format!("Bash(cat {}*)", allele_path),
            format!("Bash(find {}*)", allele_path),
            format!("Bash(ls {}*)", allele_path),
            format!("Bash(head {}*)", allele_path),
            format!("Bash(tail {}*)", allele_path),
        ];

        allow.retain(|entry| {
            let s = entry.as_str().unwrap_or("");
            !allele_entries.iter().any(|e| e == s)
        });

        for entry in &allele_entries {
            allow.push(serde_json::json!(entry));
        }
    }

    // --- additionalDirectories array ---
    if !perms
        .get("additionalDirectories")
        .map(|v| v.is_array())
        .unwrap_or(false)
    {
        perms.insert("additionalDirectories".to_string(), serde_json::json!([]));
    }

    let additional_dirs = perms
        .get_mut("additionalDirectories")
        .and_then(|v| v.as_array_mut())
        .expect("additionalDirectories is array");

    // Remove stale Locus entry (handles LOCUS_HOME changes) then re-add.
    additional_dirs.retain(|entry| entry.as_str() != Some(&locus_path));
    additional_dirs.push(serde_json::json!(locus_path));

    // Also add allele home to additionalDirectories.
    if let Some(allele_home) = dirs::home_dir().map(|h| h.join(".allele")) {
        let allele_path = allele_home.display().to_string();
        additional_dirs.retain(|entry| entry.as_str() != Some(&allele_path));
        additional_dirs.push(serde_json::json!(allele_path));
    }
}

/// Insert or replace a Locus-owned hook entry under the given hook name,
/// preserving any non-Locus matcher groups and command entries.
///
/// Claude Code's settings.json hooks schema is:
///
/// ```json
/// "hooks": {
///   "<HookName>": [
///     { "matcher": "<pattern>", "hooks": [ { "type": "command", "command": "..." } ] }
///   ]
/// }
/// ```
fn upsert_hook(
    hooks: &mut serde_json::Map<String, serde_json::Value>,
    hook_name: &str,
    matcher: Option<&str>,
    command: &str,
) {
    let matcher_str = matcher.unwrap_or("");

    // Ensure the hook array exists.
    let arr = hooks
        .entry(hook_name.to_string())
        .or_insert_with(|| serde_json::json!([]));

    let arr = match arr.as_array_mut() {
        Some(a) => a,
        None => {
            *arr = serde_json::json!([]);
            arr.as_array_mut().expect("just created")
        }
    };

    // Find an existing group with the same matcher, or create one.
    let group_idx = arr
        .iter()
        .position(|g| g.get("matcher").and_then(|m| m.as_str()).unwrap_or("") == matcher_str);

    let group_idx = match group_idx {
        Some(i) => i,
        None => {
            arr.push(serde_json::json!({
                "matcher": matcher_str,
                "hooks": []
            }));
            arr.len() - 1
        }
    };

    let group = arr[group_idx].as_object_mut().expect("group is object");

    // Ensure `hooks` child array exists.
    let group_hooks = group
        .entry("hooks".to_string())
        .or_insert_with(|| serde_json::json!([]));
    let group_hooks = match group_hooks.as_array_mut() {
        Some(a) => a,
        None => {
            *group_hooks = serde_json::json!([]);
            group_hooks.as_array_mut().expect("just created")
        }
    };

    // Remove any prior Locus-owned hook (any entry whose command starts with
    // "locus hook "). Preserve all other entries.
    group_hooks.retain(|h| {
        let cmd = h.get("command").and_then(|v| v.as_str()).unwrap_or("");
        !cmd.trim_start().starts_with("locus hook ")
    });

    // Insert the fresh Locus entry.
    group_hooks.push(serde_json::json!({
        "type": "command",
        "command": command
    }));
}

#[cfg(test)]
mod protocol_index_tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) {
        std::fs::write(dir.join(name), body).expect("write fixture");
    }

    #[test]
    fn summary_prefers_frontmatter_description() {
        let c = "---\nname: x\ndescription: How Locus does the thing\n---\n\n# Ignored Heading\n";
        assert_eq!(
            protocol_summary(c).as_deref(),
            Some("How Locus does the thing")
        );
    }

    #[test]
    fn summary_strips_quotes_from_description() {
        let c = "---\ndescription: \"Quoted summary\"\n---\n";
        assert_eq!(protocol_summary(c).as_deref(), Some("Quoted summary"));
    }

    /// The existing protocols have no frontmatter. They must index anyway, or
    /// adding the mechanism would silently require migrating every file.
    #[test]
    fn summary_falls_back_to_h1_when_no_frontmatter() {
        let c = "# Context Management Protocol\n\nHow Locus manages context.\n";
        assert_eq!(
            protocol_summary(c).as_deref(),
            Some("Context Management Protocol")
        );
    }

    #[test]
    fn summary_is_none_when_neither_present() {
        assert_eq!(protocol_summary("just prose, no heading\n"), None);
    }

    #[test]
    fn missing_directory_degrades_without_panicking() {
        let tmp = tempfile::tempdir().unwrap();
        let out = enumerate_protocols(tmp.path()); // no protocols/ subdir
        assert!(out.contains("No protocols directory"), "got: {out}");
    }

    #[test]
    fn empty_directory_degrades_without_panicking() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("protocols");
        std::fs::create_dir(&dir).unwrap();
        assert!(enumerate_protocols(tmp.path()).contains("No protocols installed"));
    }

    #[test]
    fn indexes_markdown_and_excludes_everything_else() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("protocols");
        std::fs::create_dir(&dir).unwrap();
        write(&dir, "alpha.md", "# Alpha Protocol\n");
        write(&dir, "notes.txt", "# Not A Protocol\n");
        std::fs::create_dir(dir.join("subdir")).unwrap();

        let out = enumerate_protocols(tmp.path());
        assert!(out.contains("`alpha.md` — Alpha Protocol"), "got: {out}");
        assert!(!out.contains("notes.txt"), "got: {out}");
        assert!(!out.contains("subdir"), "got: {out}");
    }

    /// Regenerating without changing anything must not produce a diff, so the
    /// order cannot depend on read_dir's arbitrary ordering.
    #[test]
    fn ordering_is_deterministic_not_filesystem_order() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("protocols");
        std::fs::create_dir(&dir).unwrap();
        for n in ["zulu.md", "alpha.md", "mike.md"] {
            write(&dir, n, "# H\n");
        }

        let out = enumerate_protocols(tmp.path());
        let order: Vec<&str> = out.lines().filter_map(|l| l.split('`').nth(1)).collect();
        assert_eq!(order, vec!["alpha.md", "mike.md", "zulu.md"]);
        assert_eq!(out, enumerate_protocols(tmp.path()), "not idempotent");
    }

    #[test]
    fn file_without_summary_is_still_listed() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("protocols");
        std::fs::create_dir(&dir).unwrap();
        write(&dir, "bare.md", "no heading here\n");
        assert!(enumerate_protocols(tmp.path()).contains("- `bare.md`"));
    }

    /// The bug this whole change exists to fix: a protocol on disk that the
    /// generated CLAUDE.md never mentions.
    #[test]
    fn generated_claude_md_names_every_installed_protocol() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("protocols");
        std::fs::create_dir(&dir).unwrap();
        write(&dir, "orchestration.md", "# Orchestration Protocol\n");
        write(&dir, "messaging.md", "# Session Messaging Protocol\n");
        write(&dir, "memory-schema.md", "# Memory Schema\n");

        let md = generate_claude_md(tmp.path());
        for f in ["orchestration.md", "messaging.md", "memory-schema.md"] {
            assert!(md.contains(f), "generated CLAUDE.md never mentions {f}");
        }
        assert!(md.contains("do not load them all"), "missing on-demand guidance");
    }
}

#[cfg(test)]
mod skill_index_tests {
    use super::*;

    /// The `delegation` skill shipped on disk and was absent from the hardcoded
    /// directive list, so no session knew it existed. Enumeration must not be
    /// able to reproduce that.
    #[test]
    fn every_installed_skill_appears_in_the_directive() {
        let tmp = tempfile::tempdir().unwrap();
        let skills = tmp.path().join("skills");
        for name in ["delegation", "research", "red-team"] {
            let d = skills.join(name);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("SKILL.md"), "# skill\n").unwrap();
        }

        let md = generate_claude_md(tmp.path());
        for name in ["delegation", "research", "red-team"] {
            assert!(md.contains(name), "directive never mentions skill {name}");
        }
    }

    #[test]
    fn directory_without_skill_md_is_not_a_skill() {
        let tmp = tempfile::tempdir().unwrap();
        let skills = tmp.path().join("skills");
        std::fs::create_dir_all(skills.join("stray")).unwrap();
        let real = skills.join("real");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join("SKILL.md"), "# s\n").unwrap();

        let out = enumerate_skills(tmp.path());
        assert_eq!(out, "real");
    }

    #[test]
    fn missing_skills_directory_degrades_without_panicking() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(enumerate_skills(tmp.path()).contains("No skills directory"));
    }
}

#[cfg(test)]
mod trait_index_tests {
    use super::*;

    /// `compose` validates against traits.yaml at runtime, so a hand-written
    /// copy in the directive could advertise a trait that does not exist, or
    /// omit one that does. Both are silent.
    #[test]
    fn directive_offers_exactly_what_traits_yaml_defines() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let yaml = repo.join("agents/traits.yaml");
        let traits = locus_core::agents::Traits::from_file(&yaml).expect("parse traits.yaml");

        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("agents")).unwrap();
        std::fs::copy(&yaml, tmp.path().join("agents/traits.yaml")).unwrap();

        let rendered = enumerate_traits(tmp.path());
        for id in traits
            .expertise
            .keys()
            .chain(traits.stance.keys())
            .chain(traits.approach.keys())
        {
            assert!(rendered.contains(id.as_str()), "trait `{id}` is never offered");
        }
    }

    #[test]
    fn missing_traits_file_degrades_without_panicking() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(enumerate_traits(tmp.path()).contains("not found"));
    }

    #[test]
    fn empty_axes_do_not_emit_a_bullet() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("agents")).unwrap();
        std::fs::write(
            tmp.path().join("agents/traits.yaml"),
            "version: \"1\"\nstance:\n  skeptical:\n    name: Skeptical\n    \
             description: d\n    prompt_fragment: p\n",
        )
        .unwrap();
        let out = enumerate_traits(tmp.path());
        assert!(out.contains("Stance"), "got: {out}");
        assert!(!out.contains("Expertise"), "empty axis emitted: {out}");
    }
}
