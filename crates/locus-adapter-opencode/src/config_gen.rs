//! OpenCode configuration generation.
//!
//! Generates the minimal configuration needed for OpenCode to use Locus:
//! - A thin `~/.config/opencode/AGENTS.md` that bootstraps Locus
//! - An `instructions` entry in `~/.config/opencode/opencode.json` that loads
//!   the Algorithm and protocols into context automatically
//!
//! Zero files are written to `.opencode/`. All Locus content stays in `~/.locus/`.

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

/// Generate the thin AGENTS.md bootstrap file.
///
/// This is placed at `~/.config/opencode/AGENTS.md` and applies to all
/// OpenCode sessions globally. It tells the AI that Locus exists and
/// where to find it. The Algorithm itself is loaded via `instructions`.
pub fn generate_agents_md(locus_home: &Path) -> String {
    format!(
        r#"# Locus

This system uses the Locus agentic workflow framework.

Locus home: {home}

Read and follow the Algorithm at `{home}/algorithm/v1.0.md` for all non-trivial requests.
For trivial requests (single file, single action, no investigation needed), handle directly.

When the Algorithm calls for skills, read the relevant skill from `{home}/skills/<skill-id>/SKILL.md`.
When the Algorithm calls for agent delegation, read agent definitions from `{home}/agents/`.
Protocols are at `{home}/protocols/`.

User data (learnings, research, work artifacts) is persisted to `{home}/data/`.
"#,
        home = locus_home.display()
    )
}

/// Write the thin AGENTS.md to the global OpenCode config directory.
///
/// Backs up any existing AGENTS.md before overwriting.
pub fn write_agents_md(locus_home: &Path) -> Result<PathBuf, LocusError> {
    let config_dir = global_config_dir()?;
    std::fs::create_dir_all(&config_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create config dir: {}", e),
        path: config_dir.clone(),
    })?;

    let agents_path = config_dir.join("AGENTS.md");

    // Back up existing AGENTS.md if it exists and wasn't created by Locus.
    if agents_path.exists() {
        let existing = std::fs::read_to_string(&agents_path).unwrap_or_default();
        if !existing.contains("# Locus") {
            let backup_path = config_dir.join("AGENTS.md.pre-locus");
            std::fs::copy(&agents_path, &backup_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to backup AGENTS.md: {}", e),
                path: backup_path,
            })?;
        }
    }

    let content = generate_agents_md(locus_home);
    std::fs::write(&agents_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write AGENTS.md: {}", e),
        path: agents_path.clone(),
    })?;

    Ok(agents_path)
}

/// Update the global `~/.config/opencode/opencode.json` with `instructions`
/// pointing at the Locus algorithm and protocols.
///
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
        let content = std::fs::read_to_string(&config_path).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read opencode.json: {}", e),
            path: config_path.clone(),
        })?;
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({
            "$schema": "https://opencode.ai/config.json"
        })
    };

    // Build the Locus instruction paths.
    let home_str = locus_home.display().to_string();
    let locus_instructions: Vec<String> = vec![
        format!("{}/algorithm/v1.0.md", home_str),
        format!("{}/protocols/degradation.md", home_str),
        format!("{}/protocols/context-management.md", home_str),
        format!("{}/protocols/memory-schema.md", home_str),
    ];

    // Merge into existing instructions array, avoiding duplicates.
    let instructions = config
        .as_object_mut()
        .unwrap()
        .entry("instructions")
        .or_insert_with(|| serde_json::json!([]));

    if let Some(arr) = instructions.as_array_mut() {
        for path in &locus_instructions {
            let val = serde_json::Value::String(path.clone());
            if !arr.contains(&val) {
                arr.push(val);
            }
        }
    }

    // Write back.
    let content =
        serde_json::to_string_pretty(&config).map_err(|e| LocusError::Adapter {
            platform: Platform::OpenCode,
            message: format!("Failed to serialise opencode.json: {}", e),
        })?;

    std::fs::write(&config_path, &content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write opencode.json: {}", e),
        path: config_path.clone(),
    })?;

    Ok(config_path)
}
