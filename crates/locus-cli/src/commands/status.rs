//! `locus status` — show a dashboard of the current installation.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use locus_core::config::LocusConfig;
use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::output;

/// Run the status command.
pub fn run() -> Result<(), LocusError> {
    let report = StatusReport::gather()?;

    output::print_header();
    output::section("Installation Status");
    output::field("Version", env!("CARGO_PKG_VERSION"));
    output::field("Platform", &report.active_platform);
    output::field("Skills", &report.skill_count);
    output::field("Data Size", &report.data_size);
    output::field("Last Sync", &report.last_sync);

    output::section("Doctor Findings");
    output::field("Issues", &report.issues.len().to_string());
    output::field("Warnings", &report.warnings.len().to_string());

    if report.issues.is_empty() && report.warnings.is_empty() {
        output::success("No issues detected by doctor.");
    } else {
        for warning in &report.warnings {
            output::warn(warning);
        }
        for issue in &report.issues {
            output::error(issue);
        }
    }

    println!();
    Ok(())
}

struct StatusReport {
    active_platform: String,
    skill_count: String,
    data_size: String,
    last_sync: String,
    issues: Vec<String>,
    warnings: Vec<String>,
}

impl StatusReport {
    fn gather() -> Result<Self, LocusError> {
        let installation = InstallationContext::discover()?;
        let findings = collect_doctor_findings(&installation);

        Ok(Self {
            active_platform: installation.active_platform_label(),
            skill_count: skill_count_label(&installation.home),
            data_size: data_size_label(&installation.data_dir),
            last_sync: last_sync_label(&installation.data_dir),
            issues: findings.issues,
            warnings: findings.warnings,
        })
    }
}

struct InstallationContext {
    home: PathBuf,
    data_dir: PathBuf,
    config: Option<LocusConfig>,
    config_issue: Option<String>,
}

impl InstallationContext {
    fn discover() -> Result<Self, LocusError> {
        let bootstrap_home = resolve_bootstrap_home()?;
        let config_path = bootstrap_home.join("locus.yaml");

        let (config, config_issue) = if config_path.exists() {
            match LocusConfig::from_file(&config_path) {
                Ok(config) => (Some(config), None),
                Err(error) => (None, Some(format!("Invalid config: {}", error))),
            }
        } else {
            (None, Some("locus.yaml not found. Run `locus init`.".into()))
        };

        let home = config
            .as_ref()
            .and_then(|config| config.resolve_home().ok())
            .unwrap_or_else(|| bootstrap_home.clone());

        let data_dir = if let Ok(env_data) = std::env::var("LOCUS_DATA_HOME") {
            PathBuf::from(env_data)
        } else {
            config
                .as_ref()
                .and_then(|config| config.resolve_data_dir().ok())
                .unwrap_or_else(|| home.join("data"))
        };

        Ok(Self {
            home,
            data_dir,
            config,
            config_issue,
        })
    }

    fn active_platform_label(&self) -> String {
        self.config
            .as_ref()
            .and_then(LocusConfig::primary_platform)
            .map(|platform| platform.display_name().to_string())
            .unwrap_or_else(|| "not configured".into())
    }
}

struct DoctorFindings {
    issues: Vec<String>,
    warnings: Vec<String>,
}

fn collect_doctor_findings(installation: &InstallationContext) -> DoctorFindings {
    let mut issues = Vec::new();
    let mut warnings = Vec::new();

    if !installation.home.exists() {
        issues.push(format!(
            "Locus home not found at {}",
            installation.home.display()
        ));
    }

    if let Some(config_issue) = &installation.config_issue {
        issues.push(config_issue.clone());
    }

    for subdir in [
        "memory/work",
        "memory/learning",
        "memory/research",
        "memory/state",
        "projects",
        "context-packs",
    ] {
        let path = installation.data_dir.join(subdir);
        if !path.exists() {
            warnings.push(format!("Missing data directory: data/{}", subdir));
        }
    }

    if let Some(config) = &installation.config {
        if config.platforms.is_empty() {
            warnings.push(
                "No platform adapters configured. Run `locus platform add <platform>`.".into(),
            );
        } else {
            for platform in &config.platforms {
                check_platform(platform, &mut issues, &mut warnings);
            }
        }
    }

    if !binary_available("git") {
        issues.push("git not found on PATH".into());
    }

    DoctorFindings { issues, warnings }
}

fn skill_count_label(home: &Path) -> String {
    let skills_dir = home.join("skills");
    match count_installed_skills(&skills_dir) {
        Some(count) => format!("{} installed", count),
        None => "unavailable".into(),
    }
}

fn count_installed_skills(skills_dir: &Path) -> Option<usize> {
    if !skills_dir.exists() {
        return Some(0);
    }

    let entries = fs::read_dir(skills_dir).ok()?;
    let mut count = 0;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && path.join("SKILL.md").exists() {
            count += 1;
        }
    }

    Some(count)
}

fn data_size_label(data_dir: &Path) -> String {
    if !data_dir.exists() {
        return "missing".into();
    }

    match directory_size_bytes(data_dir) {
        Ok(size) => format_bytes(size),
        Err(_) => "unavailable".into(),
    }
}

// Skip symlink traversal to avoid loops while sizing the tree.
fn directory_size_bytes(path: &Path) -> std::io::Result<u64> {
    let metadata = fs::symlink_metadata(path)?;

    if metadata.is_file() {
        return Ok(metadata.len());
    }

    if !metadata.is_dir() {
        return Ok(0);
    }

    let mut total = 0;
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        total += directory_size_bytes(&entry.path())?;
    }

    Ok(total)
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];

    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }

    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn last_sync_label(data_dir: &Path) -> String {
    if !data_dir.join(".git").exists() {
        return "not initialized".into();
    }

    let output = Command::new("git")
        .args(["log", "-1", "--format=%cI"])
        .current_dir(data_dir)
        .output();

    match output {
        Ok(output) if output.status.success() => {
            let timestamp = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if timestamp.is_empty() {
                "no commits".into()
            } else {
                timestamp
            }
        }
        _ => "unavailable".into(),
    }
}

fn check_platform(platform: &Platform, issues: &mut Vec<String>, warnings: &mut Vec<String>) {
    let home = match dirs::home_dir() {
        Some(home) => home,
        None => return,
    };

    let config_dir = home.join(platform.config_dir_name());
    let cli_available = binary_available(platform.cli_command());

    if config_dir.exists() && cli_available {
        return;
    }

    if config_dir.exists() {
        warnings.push(format!("{} CLI not found on PATH", platform.display_name()));
    } else {
        issues.push(format!(
            "{} is configured but not installed",
            platform.display_name()
        ));
    }
}

fn binary_available(name: &str) -> bool {
    Command::new("which")
        .arg(name)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn resolve_bootstrap_home() -> Result<PathBuf, LocusError> {
    if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        return Ok(PathBuf::from(env_home));
    }

    dirs::home_dir()
        .map(|home| home.join(".locus"))
        .ok_or_else(|| LocusError::Config {
            message: "Could not determine home directory".into(),
            path: None,
        })
}
