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

    // Generate platform-specific configuration files.
    output::section("Generating configuration");
    generate_platform_files(&config, platform, &home)?;

    println!();
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

/// Generate platform-specific configuration files.
fn generate_platform_files(
    config: &locus_core::config::LocusConfig,
    platform: Platform,
    home: &std::path::Path,
) -> Result<(), LocusError> {
    let files = match platform {
        Platform::OpenCode => {
            let adapter = locus_adapter_opencode::OpenCodeAdapter::new();
            adapter.generate_config(config)?
        }
        Platform::ClaudeCode => {
            output::info("Claude Code config generation is not yet implemented.");
            return Ok(());
        }
        _ => {
            output::info(&format!("No adapter available for {}.", platform.display_name()));
            return Ok(());
        }
    };

    let platform_config_dir = home.join(platform.config_dir_name());

    for file in &files {
        // Resolve the file path relative to either the platform config dir
        // or the current working directory.
        let target = if file.path.starts_with(".opencode") || file.path.starts_with(".claude") {
            home.join(&file.path)
        } else if file.path == std::path::Path::new("opencode.json")
            || file.path == std::path::Path::new("AGENTS.md")
        {
            // These go to the platform config dir for global use.
            platform_config_dir.join(&file.path)
        } else {
            platform_config_dir.join(&file.path)
        };

        // Don't overwrite if file exists and overwrite is false.
        if target.exists() && !file.overwrite {
            output::info(&format!(
                "Skipping {} (already exists)",
                target.display()
            ));
            continue;
        }

        // Create parent directories.
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to create directory: {}", e),
                path: parent.to_path_buf(),
            })?;
        }

        std::fs::write(&target, &file.content).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to write file: {}", e),
            path: target.clone(),
        })?;

        output::success(&format!("Generated {}", target.display()));
    }

    output::info(&format!("{} file(s) generated.", files.len()));
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
