//! OpenCode configuration generation.
//!
//! Generates the minimal configuration needed for OpenCode to use Locus:
//! - A directive `~/.config/opencode/AGENTS.md` that commands Algorithm behaviour
//! - An `instructions` entry in `~/.config/opencode/opencode.json` that loads
//!   the Algorithm and protocols into context automatically
//!
//! Zero files are written to `.opencode/`. All Locus content stays in `~/.locus/`.
//!
//! Note: AGENTS.md intentionally does NOT include the `locus delegate run`
//! directive. In the current architecture OpenCode is the BACKEND that runs
//! delegated jobs, not the orchestrator that issues them — only the Claude
//! adapter teaches delegation. Revisit if a future role lets OpenCode delegate
//! to a different backend.

use std::path::{Path, PathBuf};

use locus_core::error::LocusError;
use locus_core::platform::Platform;

/// The global OpenCode config directory.
fn global_config_dir() -> Result<PathBuf, LocusError> {
    dirs::home_dir()
        .map(|h| h.join(".config").join("opencode"))
        .ok_or_else(|| LocusError::Adapter {
            platform: Platform::OpenCode,
            message: "Could not determine home directory".into(),
        })
}

/// Whether `web_search` is enabled in the current OpenCode session, based on
/// the `OPENCODE_ENABLE_EXA` env var read at AGENTS.md generation time. Must
/// match the gate in `capabilities.rs` so the AGENTS.md tool list and the
/// in-process capability manifest stay aligned.
fn web_search_enabled_from_env() -> bool {
    std::env::var("OPENCODE_ENABLE_EXA").is_ok_and(|v| !v.is_empty() && v != "0")
}

/// Generate the AGENTS.md file with the Algorithm inlined.
///
/// This is placed at `~/.config/opencode/AGENTS.md` and applies to all
/// OpenCode sessions globally. The Algorithm is embedded directly so it's
/// guaranteed to be in the AI's context — not dependent on `instructions`
/// path resolution.
///
/// The platform-tools section is generated dynamically from the
/// `OPENCODE_ENABLE_EXA` env var: when set, `web_search` is bullet-listed
/// and the model is told it is available; otherwise it is omitted and the
/// fallback guidance to `web_fetch` / `bash` is shown. Regenerate after
/// changing the env with `locus platform add opencode`.
///
/// Source of truth for the Algorithm remains `~/.locus/algorithm/v1.1.md`.
pub fn generate_agents_md(locus_home: &Path) -> String {
    generate_agents_md_with(locus_home, web_search_enabled_from_env())
}

/// Deterministic variant of `generate_agents_md` for tests and tooling that
/// need to control the `web_search`-available bit without mutating env.
pub fn generate_agents_md_with(locus_home: &Path, web_search_available: bool) -> String {
    let home = locus_home.display();

    // Read the Algorithm from disk.
    let algorithm_path = locus_home.join("algorithm").join("v1.1.md");
    let algorithm_content = std::fs::read_to_string(&algorithm_path)
        .unwrap_or_else(|_| "<!-- Algorithm not found. Run `locus init` to install. -->".into());

    let web_search_bullet = if web_search_available {
        "\n- **web_search** (Exa) — open-ended web discovery"
    } else {
        ""
    };

    let web_search_note = if web_search_available {
        "**`web_search` is available** in this session because `OPENCODE_ENABLE_EXA=1` is set. \
         Use it for open-ended discovery; use `web_fetch` for targeted retrieval of known URLs."
    } else {
        "**`web_search` (open-ended web search) is NOT available** in this session because \
         `OPENCODE_ENABLE_EXA=1` was not set. Use `web_fetch` against known URLs or `bash` \
         with `curl`/`gh` for discovery."
    };

    format!(
        r#"# Locus

This system uses the Locus agentic workflow framework.

Locus home: {home}

Read and follow the Algorithm at `{home}/algorithm/v1.1.md` for all non-trivial requests.
For trivial requests (single file, single action, no investigation needed), handle directly.

When the Algorithm calls for skills, read the relevant skill from `{home}/skills/<skill-id>/SKILL.md`.
When the Algorithm calls for agent delegation, read agent definitions from `{home}/agents/`.
Protocols are at `{home}/protocols/`.

User data (learnings, research, work artifacts) is persisted to `{home}/data/`.

## Project Identity

When working in a project directory, Locus resolves the canonical project slug using:
1. `.locus-project` marker file (searched from `$PWD` up to `$HOME`)
2. `_registry.json` exact path match
3. `_registry.json` pattern match
4. Legacy fallback (unregistered project)

See `{home}/protocols/memory-schema.md` for full details.

## Mode Classification (MANDATORY)

Before responding to ANY user request, classify it:

- **Trivial**: Single file, single action, one clear concept, no investigation needed → handle directly without the Algorithm. **Open every trivial response with `**Classification: Trivial**` — one line, before any other content.**
- **Non-trivial**: Anything involving multiple steps, investigation, design decisions, or complex changes → ENTER THE ALGORITHM. **Open with `**Classification: Non-trivial**` before the OBSERVE phase output.**

A response without a classification line is a compliance failure — the user cannot tell Locus ran.

## Algorithm Execution (MANDATORY for non-trivial requests)

The Algorithm specification is inlined below. When entering the Algorithm, you MUST:

1. Follow the 7-phase structure: OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN
2. Start with OBSERVE: reverse-engineer the request, determine effort level, generate ISC criteria, select capabilities
3. Produce structured output with phase markers at each transition
4. Create a PRD at `{home}/data/memory/work/` to track criteria and progress
5. Never skip phases — each phase feeds the next
6. Persist learnings in the LEARN phase to `{home}/data/memory/learning/`

The Algorithm document defines effort levels (Minimal, Standard, Extended, Comprehensive),
the ISC criteria system, the Splitting Test, and the full phase specifications.
Follow it exactly.

## Skill Invocation

Skills are NOT loaded automatically. When the Algorithm's capability selection identifies
a skill, use the Read tool to load its SKILL.md from `{home}/skills/<skill-id>/SKILL.md`.
Available skills: research, first-principles, iterative-depth, council, red-team,
creative, science, extract-wisdom, documents, security, media, parser.

## Platform Tools (OpenCode)

The following native tools are available in this OpenCode session:
- **glob** — find files by pattern
- **grep** — search file contents
- **read** (view) — read files
- **edit** / **write** — modify files
- **bash** — execute shell commands
- **web_fetch** (fetch) — retrieve content from URLs
- **task** (agent) — delegate to sub-agents{web_search_bullet}

{web_search_note}
Never attempt a tool that is not in the list above.

---

{algorithm}
"#,
        home = home,
        algorithm = algorithm_content,
        web_search_bullet = web_search_bullet,
        web_search_note = web_search_note,
    )
}

/// The result of writing AGENTS.md.
pub struct AgentsMdWrite {
    /// Path to the AGENTS.md file that was written.
    pub path: PathBuf,
    /// Whether a pre-existing non-Locus AGENTS.md was backed up to `.pre-locus`.
    pub backed_up: bool,
}

/// Write the AGENTS.md to the global OpenCode config directory.
///
/// Backs up any existing non-Locus AGENTS.md to `AGENTS.md.pre-locus` before
/// overwriting. Returns both the path written and whether a backup occurred.
pub fn write_agents_md(locus_home: &Path) -> Result<AgentsMdWrite, LocusError> {
    let config_dir = global_config_dir()?;
    std::fs::create_dir_all(&config_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create config dir: {}", e),
        path: config_dir.clone(),
    })?;

    let agents_path = config_dir.join("AGENTS.md");

    // Back up existing AGENTS.md if it exists and wasn't created by Locus.
    let mut backed_up = false;
    if agents_path.exists() {
        let existing = std::fs::read_to_string(&agents_path).unwrap_or_default();
        if !existing.contains("# Locus") {
            let backup_path = config_dir.join("AGENTS.md.pre-locus");
            std::fs::copy(&agents_path, &backup_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to backup AGENTS.md: {}", e),
                path: backup_path,
            })?;
            backed_up = true;
        }
    }

    let content = generate_agents_md(locus_home);
    std::fs::write(&agents_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write AGENTS.md: {}", e),
        path: agents_path.clone(),
    })?;

    Ok(AgentsMdWrite {
        path: agents_path,
        backed_up,
    })
}

/// Update the global `~/.config/opencode/opencode.json` with `instructions`
/// pointing at the Locus algorithm and protocols.
///
/// Uses `~` tilde paths for compatibility with OpenCode's path resolution.
/// If the file doesn't exist, creates it. If it does, merges the
/// `instructions` array without clobbering other settings.
pub fn update_opencode_json(locus_home: &Path) -> Result<PathBuf, LocusError> {
    let config_dir = global_config_dir()?;
    std::fs::create_dir_all(&config_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create config dir: {}", e),
        path: config_dir.clone(),
    })?;

    let config_path = config_dir.join("opencode.json");

    // Load existing config or start fresh.
    let mut config: serde_json::Value = if config_path.exists() {
        let content =
            std::fs::read_to_string(&config_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to read opencode.json: {}", e),
                path: config_path.clone(),
            })?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({
            "$schema": "https://opencode.ai/config.json"
        })
    };

    // Build the Locus instruction paths using ~ for portability.
    let home_relative = tilde_path(locus_home);
    let locus_instructions: Vec<String> = vec![
        format!("{}/algorithm/v1.1.md", home_relative),
        format!("{}/protocols/degradation.md", home_relative),
        format!("{}/protocols/context-management.md", home_relative),
        format!("{}/protocols/memory-schema.md", home_relative),
    ];

    // Replace any existing Locus instructions, preserve non-Locus ones.
    let instructions = config
        .as_object_mut()
        .unwrap()
        .entry("instructions")
        .or_insert_with(|| serde_json::json!([]));

    if let Some(arr) = instructions.as_array_mut() {
        // Remove any existing Locus entries (contain ".locus/").
        arr.retain(|v| v.as_str().map(|s| !s.contains(".locus/")).unwrap_or(true));

        // Add the new Locus entries.
        for path in &locus_instructions {
            arr.push(serde_json::Value::String(path.clone()));
        }
    }

    // Merge Locus read/edit permissions for the data directory.
    merge_locus_permissions(&mut config, locus_home);

    // Write back.
    let content = serde_json::to_string_pretty(&config).map_err(|e| LocusError::Adapter {
        platform: Platform::OpenCode,
        message: format!("Failed to serialise opencode.json: {}", e),
    })?;

    std::fs::write(&config_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write opencode.json: {}", e),
        path: config_path.clone(),
    })?;

    Ok(config_path)
}

/// Merge Locus permission entries into a parsed opencode.json value.
///
/// Pre-allows read access to the entire `locus_home` directory so the AI can
/// load skills, agents, algorithms, and protocols without prompting.
/// Pre-allows edit access only to `locus_home/data/**` so PRDs, checkpoints,
/// and learnings can be written without prompting.
/// Also pre-allows read and write access to the allele home directory so the
/// AI can operate on allele workspaces without prompting.
/// Existing non-Locus permissions are preserved. The merge is idempotent.
pub fn merge_locus_permissions(config: &mut serde_json::Value, locus_home: &Path) {
    if !config.is_object() {
        *config = serde_json::json!({});
    }

    let locus_path = locus_home.display().to_string();
    let read_path = format!("{}/**", locus_path);
    let edit_path = format!("{}/data/**", locus_path);

    let root = config.as_object_mut().expect("config is object");

    // Ensure permissions object exists.
    if !root.get("permission").map(|v| v.is_object()).unwrap_or(false) {
        root.insert("permission".to_string(), serde_json::json!({}));
    }

    let permissions = root
        .get_mut("permission")
        .and_then(|v| v.as_object_mut())
        .expect("permission exists and is object");

    // --- read: whole locus home ---
    if !permissions.get("read").map(|v| v.is_object()).unwrap_or(false) {
        permissions.insert("read".to_string(), serde_json::json!({}));
    }
    let read_perms = permissions
        .get_mut("read")
        .and_then(|v| v.as_object_mut())
        .expect("read perms is object");
    read_perms.retain(|k, _| !k.contains(".locus/"));
    read_perms.insert(read_path, serde_json::json!("allow"));

    // --- edit: only data directory ---
    if !permissions.get("edit").map(|v| v.is_object()).unwrap_or(false) {
        permissions.insert("edit".to_string(), serde_json::json!({}));
    }
    let edit_perms = permissions
        .get_mut("edit")
        .and_then(|v| v.as_object_mut())
        .expect("edit perms is object");
    edit_perms.retain(|k, _| !k.contains(".locus/"));
    edit_perms.insert(edit_path, serde_json::json!("allow"));

    // --- allele workspaces: read + write ---
    if let Some(allele_home) = dirs::home_dir().map(|h| h.join(".allele")) {
        let allele_path = allele_home.display().to_string();
        let allele_read = format!("{}/**", allele_path);
        let allele_edit = format!("{}/**", allele_path);

        let read_perms = permissions
            .get_mut("read")
            .and_then(|v| v.as_object_mut())
            .expect("read perms is object");
        read_perms.retain(|k, _| !k.contains(".allele/"));
        read_perms.insert(allele_read, serde_json::json!("allow"));

        let edit_perms = permissions
            .get_mut("edit")
            .and_then(|v| v.as_object_mut())
            .expect("edit perms is object");
        edit_perms.retain(|k, _| !k.contains(".allele/"));
        edit_perms.insert(allele_edit, serde_json::json!("allow"));
    }
}

/// Convert an absolute path to a tilde path (e.g., /Users/foo/.locus -> ~/.locus).
fn tilde_path(path: &Path) -> String {
    if let Some(home) = dirs::home_dir() {
        if let Ok(relative) = path.strip_prefix(&home) {
            return format!("~/{}", relative.display());
        }
    }
    path.display().to_string()
}

// ----------------------------------------------------------------------------
// Native config — for sessions spawned in `ExecutionMode::Native`.
//
// Lives at `~/.locus/opencode-native-xdg/opencode/` so that setting
// `XDG_CONFIG_HOME=~/.locus/opencode-native-xdg` on the spawned process
// causes OpenCode to read this isolated config instead of the global
// `~/.config/opencode/`. Auth (XDG_DATA_HOME) is shared.
// ----------------------------------------------------------------------------

/// Path to the native XDG_CONFIG_HOME used for delegated sessions.
pub fn native_xdg_config_dir(locus_home: &Path) -> PathBuf {
    locus_home.join("opencode-native-xdg")
}

/// Path to the per-app native opencode config directory (`<xdg>/opencode`).
fn native_opencode_dir(locus_home: &Path) -> PathBuf {
    native_xdg_config_dir(locus_home).join("opencode")
}

/// Generate the AGENTS.md content for a native delegated session.
///
/// Deliberately thin: tells the model it is a delegated worker, that the
/// prompt is its task, and that orchestration scaffolding does NOT apply.
/// This text is the antithesis of `generate_agents_md` — no Algorithm,
/// no Mode Classification, no skills loading.
pub fn generate_native_agents_md() -> String {
    r#"# Delegated worker session

You are a worker spawned by a Locus orchestrator (typically via `locus delegate run`).
The orchestrator is the *outer* session. You are *not* the orchestrator.

## Your job

Read the user prompt. Use the tools available to do the work the prompt describes.
Produce the requested output (a research dossier, a code-exploration summary, an
extracted answer — whatever the prompt asks for) directly in your response.

## What you must NOT do

- Do not classify the request as Trivial / Non-trivial.
- Do not run OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN phases.
- Do not write a PRD, checkpoint, or learning file.
- Do not invoke skills, agents, or protocols. They do not apply here.
- Do not delegate further (you are already a delegate).

If the prompt itself describes a multi-step process, follow that process — but do
not impose your own orchestration framework on top of it.

## Tools

Use the tools your runtime provides (read, edit/write, bash, web_fetch, web_search
when available). Verify every URL you cite. If a tool you would normally reach for
is not available, say so in your output and proceed with what you have.
"#
    .to_string()
}

/// Generate the minimal `opencode.json` for a native delegated session.
///
/// No `instructions:` array — that's the whole point of native mode.
///
/// Permissions: a delegated session has no human to answer "ask" prompts,
/// so every permission that defaults to `ask` aborts the run silently. We
/// pre-allow the safe-for-delegation set:
/// - `doom_loop`: OpenCode's "agent appears to be repeating" check. In CLI
///   `ask` aborts; for bounded research delegations we want to keep going.
/// - `external_directory`: agents reading files outside `--dir` (e.g. shared
///   docs) should not abort.
/// - `webfetch`/`websearch`: research delegation needs the web.
/// - `bash`: tools like `curl`/`gh` are common research utilities.
/// - `todowrite`/`question`: ask-by-default but harmless inside a delegate.
///
/// `edit` is explicitly `deny` to enforce the read-only delegation contract
/// at the OpenCode permission layer (belt-and-braces with the existing
/// `DelegationMode::ReadOnly` validation in the runner).
fn generate_native_opencode_json() -> String {
    let value = serde_json::json!({
        "$schema": "https://opencode.ai/config.json",
        "permission": {
            "doom_loop": "allow",
            "external_directory": "allow",
            "webfetch": "allow",
            "websearch": "allow",
            "bash": "allow",
            "todowrite": "allow",
            "question": "allow",
            "edit": "deny"
        }
    });
    serde_json::to_string_pretty(&value).expect("static JSON serialises")
}

/// Write the native config bundle (AGENTS.md + opencode.json) under
/// `~/.locus/opencode-native-xdg/opencode/`. Idempotent.
pub fn write_native_config(locus_home: &Path) -> Result<NativeConfigWrite, LocusError> {
    let dir = native_opencode_dir(locus_home);
    std::fs::create_dir_all(&dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create native config dir: {}", e),
        path: dir.clone(),
    })?;

    let agents_path = dir.join("AGENTS.md");
    std::fs::write(&agents_path, generate_native_agents_md()).map_err(|e| {
        LocusError::Filesystem {
            message: format!("Failed to write native AGENTS.md: {}", e),
            path: agents_path.clone(),
        }
    })?;

    let config_path = dir.join("opencode.json");
    std::fs::write(&config_path, generate_native_opencode_json()).map_err(|e| {
        LocusError::Filesystem {
            message: format!("Failed to write native opencode.json: {}", e),
            path: config_path.clone(),
        }
    })?;

    Ok(NativeConfigWrite {
        agents_md_path: agents_path,
        config_path,
    })
}

/// Result of writing the native config bundle.
pub struct NativeConfigWrite {
    /// Path to the native AGENTS.md.
    pub agents_md_path: PathBuf,
    /// Path to the native opencode.json.
    pub config_path: PathBuf,
}
