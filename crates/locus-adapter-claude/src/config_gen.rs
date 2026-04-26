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
pub fn generate_claude_md(locus_home: &Path) -> String {
    let home = locus_home.display();

    // Read the Algorithm from disk — falls back to a placeholder if it's not
    // yet installed, which is the only reasonable degraded mode.
    let algorithm_path = locus_home.join("algorithm").join("v1.1.md");
    let algorithm_content = std::fs::read_to_string(&algorithm_path)
        .unwrap_or_else(|_| "<!-- Algorithm not found. Run `locus init` to install. -->".into());

    format!(
        r#"# Locus

This system uses the Locus agentic workflow framework.

Locus home: {home}

Read and follow the Algorithm at `{home}/algorithm/v1.1.md` for all non-trivial requests.
For trivial requests (single file, single action, no investigation needed), handle directly.

When the Algorithm calls for skills, read the relevant skill from `{home}/skills/<skill-id>/SKILL.md` via the Read tool.
When the Algorithm calls for agent delegation, read agent definitions from `{home}/agents/` via the Read tool, then delegate via `locus delegate run`.
Protocols are at `{home}/protocols/`.

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

Available skills: research, first-principles, iterative-depth, council, red-team, creative, science, extract-wisdom, documents, security, media, parser.

## Delegation Guardrail

Any agent-style delegation MUST go through `locus delegate run`. Do not use platform-native Task/Agent subagents for research, code exploration, council/red-team work, or any other delegated agent work. Native subagents burn orchestrator context and bypass Locus's compact result envelope.

If `locus delegate run` is unavailable or failing, do not fall back to native Task/Agent delegation. Continue serially or ask the user how to proceed.

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

**Invocation:**

```bash
locus delegate run \
  --backend opencode \
  --task-kind research \
  --mode native \
  --model openai/gpt-5.5 \
  --dir <workspace> \
  --prompt "<bounded task>" \
  --output json
```

Use `--task-kind code-exploration` for codebase mapping and `--task-kind general` for everything else. Substitute `<provider/model>` to match the work — research benefits from larger models; mapping is fine on cheaper ones.

**`--mode native` is the default and almost always what you want.** It runs the delegated session with no Locus orchestration scaffolding loaded — the delegated model just reads the prompt and produces the requested output, no `OBSERVE → THINK → PLAN` phases, no Mode Classification. Use `--mode algorithmic` *only* in the rare case the delegated session itself needs to orchestrate (you almost never want this; the orchestrator is *this* session, not the delegate). Algorithmic mode loads the full Locus Algorithm into the delegate, making it act like a second orchestrator — which usually means the delegate burns its turn writing phase scaffolding instead of doing the work. If you omit `--mode`, you get native.

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
