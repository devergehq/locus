//! Claude Code settings support.
//!
//! Locus no longer generates `~/.claude/CLAUDE.md` and no longer merges
//! `locus hook *` entries into `~/.claude/settings.json` — the Claude Code
//! plugin supplies the directive and the hooks (see `.claude-plugin/`).
//!
//! Two things a plugin manifest cannot carry remain this module's job, because
//! `statusLine` and `permissions` are `settings.json` fields with no manifest
//! equivalent (both probed under `claude plugin validate --strict` and rejected
//! as unknown manifest fields):
//!
//! - `statusLine` — pointed at `{locus_home}/scripts/statusline.sh`, and only
//!   when the existing entry is absent or already Locus-owned.
//! - `permissions.allow` — read access across `~/.locus/`, write access to
//!   `~/.locus/data/` so the Algorithm can persist PRDs, checkpoints and
//!   learnings without a prompt on every non-trivial turn.
//!
//! Teardown of what older versions wrote lives in [`crate::teardown`].

use std::path::{Path, PathBuf};

use locus_core::error::LocusError;
use locus_core::platform::Platform;

/// The global Claude Code config directory (`~/.claude/`).
pub(crate) fn global_config_dir() -> Result<PathBuf, LocusError> {
    dirs::home_dir()
        .map(|h| h.join(".claude"))
        .ok_or_else(|| LocusError::Adapter {
            platform: Platform::ClaudeCode,
            message: "Could not determine home directory".into(),
        })
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

/// Write the Locus-owned parts of `~/.claude/settings.json`.
///
/// Writes `statusLine` and `permissions.allow` only — no hook entries, and no
/// `CLAUDE.md`. Both merges preserve anything they do not own, so this is safe
/// to re-run. Returns the path that was written.
pub fn write_locus_settings(locus_home: &Path) -> Result<PathBuf, LocusError> {
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
