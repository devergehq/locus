//! `locus platform` — manage platform adapters.

use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::output;

/// List all supported platforms and their detection status.
pub fn list() -> Result<(), LocusError> {
    output::print_header();
    output::section("Platforms");

    let home = dirs::home_dir().ok_or_else(|| LocusError::Config {
        message: "Could not determine home directory".into(),
        path: None,
    })?;

    for platform in Platform::all() {
        let config_dir = home.join(platform.config_dir_name());
        let config_exists = config_dir.exists();

        let cli_available = std::process::Command::new("which")
            .arg(platform.cli_command())
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        let status = match (config_exists, cli_available) {
            (true, true) => "installed",
            (true, false) => "config only (CLI not found)",
            (false, true) => "CLI only (not configured)",
            (false, false) => "not installed",
        };

        output::list_item(platform.display_name(), status);
    }

    println!();
    Ok(())
}

/// Add a platform adapter.
pub fn add(platform_str: &str) -> Result<(), LocusError> {
    output::print_header();

    let platform = parse_platform(platform_str)?;
    let locus_home = resolve_locus_home()?;
    let config_path = locus_home.join("locus.yaml");

    if !config_path.exists() {
        output::error("Locus is not initialised. Run `locus init` first.");
        return Err(LocusError::Config {
            message: "Not initialised".into(),
            path: Some(config_path),
        });
    }

    output::section(&format!(
        "Setting up {} with Locus",
        platform.display_name()
    ));

    // Update locus.yaml with the platform.
    let mut config = locus_core::config::LocusConfig::from_file(&config_path)?;
    if config.platforms.contains(&platform) {
        output::info(&format!(
            "{} is already in locus.yaml.",
            platform.display_name()
        ));
    } else {
        config.platforms.push(platform);
        let yaml = config.to_yaml()?;
        std::fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to write config: {}", e),
            path: config_path.clone(),
        })?;
        output::success(&format!("Added {} to locus.yaml", platform.display_name()));
    }

    // Platform-specific setup.
    match platform {
        Platform::OpenCode => setup_opencode(&locus_home)?,
        Platform::ClaudeCode => setup_claude(&locus_home)?,
        _ => {
            output::info(&format!(
                "No adapter available for {}.",
                platform.display_name()
            ));
        }
    }

    println!();
    Ok(())
}

/// Set up Locus for OpenCode.
fn setup_opencode(locus_home: &std::path::Path) -> Result<(), LocusError> {
    let adapter = locus_adapter_opencode::OpenCodeAdapter::new();
    let result = adapter.setup(locus_home)?;

    output::success(&format!("Wrote {}", result.agents_md_path.display()));
    output::success(&format!("Updated {}", result.config_path.display()));

    output::section("What was configured");
    output::info(&format!(
        "AGENTS.md  — thin Locus bootstrap at {}",
        result.agents_md_path.display()
    ));
    output::info(&format!(
        "opencode.json — instructions pointing at {}/algorithm/ and {}/protocols/",
        locus_home.display(),
        locus_home.display()
    ));
    output::info(&format!(
        "opencode.json — read permission for all of {} (skills, agents, protocols)",
        locus_home.display()
    ));
    output::info(&format!(
        "opencode.json — edit permission for {}/data/ only (PRDs, checkpoints, learnings)",
        locus_home.display()
    ));

    output::section("How it works");
    output::info("OpenCode loads the Locus Algorithm into every session via instructions.");
    output::info(
        "The Algorithm orchestrates skills and agents — reading them from ~/.locus/ as needed.",
    );
    output::info("Zero files were written to .opencode/. All content stays in Locus.");

    Ok(())
}

/// Set up Locus for Claude Code.
///
/// The plugin supplies the directive and the hooks, so this writes only the two
/// `settings.json` fields a plugin manifest cannot express.
fn setup_claude(locus_home: &std::path::Path) -> Result<(), LocusError> {
    let adapter = locus_adapter_claude::ClaudeAdapter::new();
    let result = adapter.setup(locus_home)?;

    output::success(&format!("Updated {}", result.settings_path.display()));

    output::section("What was configured");
    output::info(
        "settings.json — read-access permissions for the Locus home directory (Read tool + cat/find/ls/head/tail)",
    );
    output::info(&format!(
        "settings.json — statusLine pointed at {}/scripts/statusline.sh",
        locus_home.display()
    ));

    output::section("What was NOT configured");
    output::info("CLAUDE.md     — the Locus plugin supplies the directive.");
    output::info("settings.json — hook entries come from the plugin's hooks.json, not from here.");
    output::info("Run `locus platform remove claude-code` to clear config an older version wrote.");

    output::section("How it works");
    output::info("Claude Code loads the Locus Algorithm into every session via the plugin.");
    output::info(
        "The Algorithm orchestrates skills and agents — reading them from ~/.locus/ via the Read tool.",
    );

    Ok(())
}

/// Remove a platform adapter.
///
/// For Claude Code this also clears the configuration older Locus versions
/// wrote into `~/.claude/` — the generated `CLAUDE.md` and `locus hook *`
/// entries in `settings.json`. Permissions, the statusline and every non-Locus
/// hook are left alone.
pub fn remove(platform_str: &str, dry_run: bool) -> Result<(), LocusError> {
    output::print_header();

    let platform = parse_platform(platform_str)?;

    output::section(&format!("Removing {} adapter", platform.display_name()));
    if dry_run {
        output::info("Dry run — nothing will be written.");
    }

    let locus_home = resolve_locus_home()?;
    let config_path = locus_home.join("locus.yaml");

    if !config_path.exists() {
        output::error("Locus is not initialised. Run `locus init` first.");
        return Err(LocusError::Config {
            message: "Not initialised".into(),
            path: Some(config_path),
        });
    }

    // Platform-specific config teardown.
    if platform == Platform::ClaudeCode {
        teardown_claude(dry_run)?;
    }

    let mut config = locus_core::config::LocusConfig::from_file(&config_path)?;
    let before = config.platforms.len();
    config.platforms.retain(|p| p != &platform);

    if config.platforms.len() < before {
        if dry_run {
            output::info(&format!(
                "Would remove {} from locus.yaml",
                platform.display_name()
            ));
        } else {
            let yaml = config.to_yaml()?;
            std::fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to write config: {}", e),
                path: config_path.clone(),
            })?;
            output::success(&format!(
                "Removed {} from locus.yaml",
                platform.display_name()
            ));
        }
    } else {
        output::info(&format!("{} was not configured.", platform.display_name()));
    }

    println!();
    Ok(())
}

/// Clear the Locus-owned configuration from `~/.claude/`, reporting exactly
/// what was (or under `--dry-run`, would be) removed.
fn teardown_claude(dry_run: bool) -> Result<(), LocusError> {
    let adapter = locus_adapter_claude::ClaudeAdapter::new();
    let removal = adapter.teardown(dry_run)?;

    let verb = if dry_run { "Would remove" } else { "Removed" };

    if let Some(path) = &removal.claude_md {
        output::success(&format!("{} {}", verb, path.display()));
        if let Some(backup) = &removal.claude_md_backup {
            output::info(&format!(
                "{} backed up to {}",
                if dry_run { "Would be" } else { "Backed up" },
                backup.display()
            ));
        }
    }

    if let Some(path) = &removal.foreign_claude_md {
        output::info(&format!(
            "Left {} in place — it carries no Locus marker, so it is not ours.",
            path.display()
        ));
    }

    if removal.hooks.is_empty() {
        output::info("No `locus hook` entries found in settings.json.");
    } else {
        output::success(&format!(
            "{} {} `locus hook` entr{} from settings.json",
            verb,
            removal.hooks.len(),
            if removal.hooks.len() == 1 { "y" } else { "ies" }
        ));
        for hook in &removal.hooks {
            output::info(&format!("  {} — {}", hook.event, hook.command));
        }
    }

    if let Some(path) = &removal.unparsable_settings {
        output::warn(&format!(
            "{} is not valid JSON — left untouched. Fix it and re-run.",
            path.display()
        ));
    }

    if removal.is_empty() {
        output::info("Nothing to remove — no Locus-owned Claude Code config found.");
    }

    output::section("Left untouched");
    output::info(
        "permissions.allow — Locus still needs these; a plugin manifest cannot grant them.",
    );
    output::info("statusLine        — same reason. Clear it yourself if you want it gone.");
    output::info("Every non-Locus hook, including tokenmaxer.");

    Ok(())
}

/// Resolve the Locus home directory, respecting LOCUS_HOME env var.
fn resolve_locus_home() -> Result<std::path::PathBuf, LocusError> {
    if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        return Ok(std::path::PathBuf::from(env_home));
    }
    dirs::home_dir()
        .map(|h| h.join(".locus"))
        .ok_or_else(|| LocusError::Config {
            message: "Could not determine home directory".into(),
            path: None,
        })
}

/// Parse a platform string into a Platform enum.
fn parse_platform(s: &str) -> Result<Platform, LocusError> {
    match s.to_lowercase().as_str() {
        "claude-code" | "claude" | "claudecode" => Ok(Platform::ClaudeCode),
        "opencode" | "open-code" => Ok(Platform::OpenCode),
        _ => {
            let supported: Vec<&str> = Platform::all()
                .iter()
                .map(|p| p.config_dir_name().trim_start_matches('.'))
                .collect();
            Err(LocusError::Config {
                message: format!(
                    "Unknown platform '{}'. Supported: {}",
                    s,
                    supported.join(", ")
                ),
                path: None,
            })
        }
    }
}
