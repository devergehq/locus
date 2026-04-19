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

    output::section(&format!("Setting up {} with Locus", platform.display_name()));

    // Update locus.yaml with the platform.
    let mut config = locus_core::config::LocusConfig::from_file(&config_path)?;
    if config.platforms.contains(&platform) {
        output::info(&format!("{} is already in locus.yaml.", platform.display_name()));
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
        Platform::ClaudeCode => {
            output::info("Claude Code adapter is not yet implemented.");
        }
        _ => {
            output::info(&format!("No adapter available for {}.", platform.display_name()));
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

    output::section("How it works");
    output::info("OpenCode loads the Locus Algorithm into every session via instructions.");
    output::info("The Algorithm orchestrates skills and agents — reading them from ~/.locus/ as needed.");
    output::info("Zero files were written to .opencode/. All content stays in Locus.");

    Ok(())
}

/// Remove a platform adapter.
pub fn remove(platform_str: &str) -> Result<(), LocusError> {
    output::print_header();

    let platform = parse_platform(platform_str)?;

    output::section(&format!("Removing {} adapter", platform.display_name()));

    let locus_home = resolve_locus_home()?;
    let config_path = locus_home.join("locus.yaml");

    if !config_path.exists() {
        output::error("Locus is not initialised. Run `locus init` first.");
        return Err(LocusError::Config {
            message: "Not initialised".into(),
            path: Some(config_path),
        });
    }

    let mut config = locus_core::config::LocusConfig::from_file(&config_path)?;
    let before = config.platforms.len();
    config.platforms.retain(|p| p != &platform);

    if config.platforms.len() < before {
        let yaml = config.to_yaml()?;
        std::fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to write config: {}", e),
            path: config_path.clone(),
        })?;
        output::success(&format!("Removed {} from locus.yaml", platform.display_name()));
    } else {
        output::info(&format!("{} was not configured.", platform.display_name()));
    }

    println!();
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
