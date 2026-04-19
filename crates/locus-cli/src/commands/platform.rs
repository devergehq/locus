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

    output::section(&format!("Adding {} adapter", platform.display_name()));

    // Check if the platform is actually installed.
    let home = dirs::home_dir().ok_or_else(|| LocusError::Config {
        message: "Could not determine home directory".into(),
        path: None,
    })?;

    let config_dir = home.join(platform.config_dir_name());
    if !config_dir.exists() {
        output::warn(&format!(
            "{} config directory not found at {}",
            platform.display_name(),
            config_dir.display()
        ));
        output::info(&format!(
            "Install {} first, then run this command again.",
            platform.display_name()
        ));
        return Ok(());
    }

    // Load Locus config.
    let locus_home = home.join(".locus");
    let config_path = locus_home.join("locus.yaml");

    if !config_path.exists() {
        output::error("Locus is not initialised. Run `locus init` first.");
        return Err(LocusError::Config {
            message: "Not initialised".into(),
            path: Some(config_path),
        });
    }

    let mut config = locus_core::config::LocusConfig::from_file(&config_path)?;

    // Add platform if not already present.
    if config.platforms.contains(&platform) {
        output::info(&format!(
            "{} is already configured.",
            platform.display_name()
        ));
    } else {
        config.platforms.push(platform);
        let yaml = config.to_yaml()?;
        std::fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to write config: {}", e),
            path: config_path.clone(),
        })?;
        output::success(&format!(
            "Added {} to locus.yaml",
            platform.display_name()
        ));
    }

    // TODO: Phase 4/5 — call adapter.generate_config() to produce platform files.
    output::info("Platform config generation will be available after adapter implementation.");

    println!();
    Ok(())
}

/// Remove a platform adapter.
pub fn remove(platform_str: &str) -> Result<(), LocusError> {
    output::print_header();

    let platform = parse_platform(platform_str)?;

    output::section(&format!("Removing {} adapter", platform.display_name()));

    let home = dirs::home_dir().ok_or_else(|| LocusError::Config {
        message: "Could not determine home directory".into(),
        path: None,
    })?;

    let locus_home = home.join(".locus");
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
        output::success(&format!(
            "Removed {} from locus.yaml",
            platform.display_name()
        ));
    } else {
        output::info(&format!(
            "{} was not configured.",
            platform.display_name()
        ));
    }

    println!();
    Ok(())
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
