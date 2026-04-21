//! `locus doctor` — validate the Locus installation.

use std::path::PathBuf;

use locus_core::config::LocusConfig;
use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::output;

/// Run the doctor command.
pub fn run() -> Result<(), LocusError> {
    output::print_header();
    output::section("System Check");

    let home = resolve_home()?;
    let mut issues: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    // 1. Check Locus home exists.
    check_directory(&home, "Locus home", &mut issues);

    // 2. Check config file.
    let config_path = home.join("locus.yaml");
    let config = check_config(&config_path, &mut issues);

    // 3. Check data directories.
    output::section("Data Directories");
    let data_dir = config
        .as_ref()
        .and_then(|c| c.resolve_data_dir().ok())
        .unwrap_or_else(|| home.join("data"));

    for subdir in &[
        "memory/work",
        "memory/learning",
        "memory/research",
        "memory/state",
        "projects",
        "context-packs",
    ] {
        let path = data_dir.join(subdir);
        if path.exists() {
            output::success(&format!("data/{}", subdir));
        } else {
            output::warn(&format!("data/{} — missing", subdir));
            warnings.push(format!("Missing data directory: data/{}", subdir));
        }
    }

    // 4. Check traits.yaml and agent composition.
    output::section("Agent Composition");
    check_traits(&home, &mut issues, &mut warnings);

    // 5. Check platforms.
    output::section("Platforms");
    if let Some(ref config) = config {
        if config.platforms.is_empty() {
            output::warn("No platforms configured");
            warnings.push(
                "No platform adapters configured. Run `locus platform add <platform>`.".into(),
            );
        } else {
            for platform in &config.platforms {
                check_platform(platform, &mut issues, &mut warnings);
            }
        }
    }

    // 5. Check platform binaries.
    output::section("External Tools");
    check_binary("git", "Git (required for sync)", &mut issues);

    // Summary.
    output::section("Summary");
    if issues.is_empty() && warnings.is_empty() {
        output::success("All checks passed");
    } else {
        if !warnings.is_empty() {
            for w in &warnings {
                output::warn(w);
            }
        }
        if !issues.is_empty() {
            for i in &issues {
                output::error(i);
            }
        }
        println!();
        output::info(&format!(
            "{} issue(s), {} warning(s)",
            issues.len(),
            warnings.len()
        ));
    }

    println!();
    Ok(())
}

fn resolve_home() -> Result<PathBuf, LocusError> {
    if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        return Ok(PathBuf::from(env_home));
    }
    dirs::home_dir()
        .map(|h| h.join(".locus"))
        .ok_or_else(|| LocusError::Config {
            message: "Could not determine home directory".into(),
            path: None,
        })
}

fn check_directory(path: &PathBuf, label: &str, issues: &mut Vec<String>) {
    if path.exists() {
        output::success(&format!("{} ({})", label, path.display()));
    } else {
        output::error(&format!("{} — not found ({})", label, path.display()));
        issues.push(format!("{} not found at {}", label, path.display()));
    }
}

fn check_config(path: &PathBuf, issues: &mut Vec<String>) -> Option<LocusConfig> {
    if !path.exists() {
        output::error(&format!("Config — not found ({})", path.display()));
        issues.push("locus.yaml not found. Run `locus init`.".into());
        return None;
    }

    match LocusConfig::from_file(path) {
        Ok(config) => {
            output::success(&format!("Config — valid ({})", path.display()));
            Some(config)
        }
        Err(e) => {
            output::error(&format!("Config — invalid: {}", e));
            issues.push(format!("Invalid config: {}", e));
            None
        }
    }
}

fn check_traits(home: &PathBuf, issues: &mut Vec<String>, warnings: &mut Vec<String>) {
    let traits_path = home.join("agents").join("traits.yaml");
    match locus_core::Traits::from_file(&traits_path) {
        Ok(traits) => {
            let total = traits.expertise.len() + traits.stance.len() + traits.approach.len();
            if total == 0 {
                output::error("traits.yaml parses but contains no traits");
                issues.push("traits.yaml has zero traits across all axes".into());
                return;
            }
            output::success(&format!(
                "traits.yaml — {} expertise, {} stance, {} approach ({} total)",
                traits.expertise.len(),
                traits.stance.len(),
                traits.approach.len(),
                total,
            ));

            // Smoke-test composition with the first trait from each axis.
            let mut sample: Vec<&str> = Vec::new();
            if let Some((id, _)) = traits.expertise.iter().next() {
                sample.push(id.as_str());
            }
            if let Some((id, _)) = traits.stance.iter().next() {
                sample.push(id.as_str());
            }
            if let Some((id, _)) = traits.approach.iter().next() {
                sample.push(id.as_str());
            }
            match traits.compose(&sample, Some("doctor-smoke-test"), None) {
                Ok(composed) if !composed.prompt.is_empty() => {
                    output::success("agent composition smoke-test passed");
                }
                Ok(_) => {
                    output::warn("agent composition produced an empty prompt");
                    warnings.push("agent compose smoke-test returned empty prompt".into());
                }
                Err(e) => {
                    output::error(&format!("agent composition failed: {}", e));
                    issues.push(format!("agent compose smoke-test error: {}", e));
                }
            }
        }
        Err(e) => {
            if traits_path.exists() {
                output::error(&format!("traits.yaml — invalid: {}", e));
                issues.push(format!("Invalid agents/traits.yaml: {}", e));
            } else {
                output::warn("traits.yaml — not found (run `locus init`)");
                warnings.push("agents/traits.yaml missing".into());
            }
        }
    }
}

fn check_platform(platform: &Platform, issues: &mut Vec<String>, warnings: &mut Vec<String>) {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };

    let config_dir = home.join(platform.config_dir_name());
    let cli_available = std::process::Command::new("which")
        .arg(platform.cli_command())
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if config_dir.exists() && cli_available {
        output::success(&format!(
            "{} — config dir and CLI found",
            platform.display_name()
        ));
    } else if config_dir.exists() {
        output::warn(&format!(
            "{} — config dir found but `{}` CLI not on PATH",
            platform.display_name(),
            platform.cli_command()
        ));
        warnings.push(format!("{} CLI not found on PATH", platform.display_name()));
    } else {
        output::error(&format!(
            "{} — not installed (no {} directory)",
            platform.display_name(),
            platform.config_dir_name()
        ));
        issues.push(format!(
            "{} is configured but not installed",
            platform.display_name()
        ));
    }

    // Platform-specific integration checks.
    if *platform == Platform::ClaudeCode && config_dir.exists() {
        check_claude_integration(&config_dir, issues, warnings);
    }
}

fn check_claude_integration(
    config_dir: &std::path::Path,
    issues: &mut Vec<String>,
    warnings: &mut Vec<String>,
) {
    let claude_md = config_dir.join("CLAUDE.md");
    match std::fs::read_to_string(&claude_md) {
        Ok(content) if content.contains("# Locus") => {
            output::success("Claude Code CLAUDE.md — Locus bootstrap detected");
        }
        Ok(_) => {
            output::warn("Claude Code CLAUDE.md exists but is not a Locus bootstrap");
            warnings.push(
                "CLAUDE.md does not contain '# Locus'. Run `locus platform add claude-code`."
                    .into(),
            );
        }
        Err(_) => {
            output::error("Claude Code CLAUDE.md not found");
            issues.push(
                "CLAUDE.md missing. Run `locus platform add claude-code` to generate it.".into(),
            );
        }
    }

    let settings = config_dir.join("settings.json");
    if let Ok(content) = std::fs::read_to_string(&settings) {
        if content.contains("locus hook ") {
            output::success("Claude Code settings.json — Locus hooks detected");
        } else {
            output::warn("Claude Code settings.json has no Locus hooks");
            warnings
                .push("settings.json missing Locus hooks. Re-run `locus platform add claude-code`.".into());
        }
    } else {
        output::warn("Claude Code settings.json not found");
        warnings.push("settings.json missing. Re-run `locus platform add claude-code`.".into());
    }

    // Check `locus` itself is on PATH (hooks rely on this).
    let locus_on_path = std::process::Command::new("which")
        .arg("locus")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if !locus_on_path {
        output::error("`locus` binary not on PATH — hooks will fail to execute");
        issues.push("locus must be on PATH for Claude Code hooks to fire. Add it.".into());
    }
}

fn check_binary(name: &str, label: &str, issues: &mut Vec<String>) {
    let available = std::process::Command::new("which")
        .arg(name)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if available {
        output::success(label);
    } else {
        output::error(&format!("{} — not found", label));
        issues.push(format!("{} not found on PATH", name));
    }
}
