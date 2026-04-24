//! `locus init` — scaffold a new Locus installation.

use std::fs;
use std::path::PathBuf;

use locus_core::config::{
    AlgorithmConfig, InferenceConfig, LocusConfig, NotificationConfig, PathConfig, SkillConfig,
};
use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::output;

/// Run the init command.
pub fn run(bare: bool) -> Result<(), LocusError> {
    output::print_header();
    output::section("Initialising Locus");

    let home = resolve_locus_home()?;

    // Check if already initialised.
    let config_path = home.join("locus.yaml");
    if config_path.exists() {
        output::warn(&format!(
            "Locus is already initialised at {}",
            home.display()
        ));
        output::info("Run `locus doctor` to validate your installation.");
        return Ok(());
    }

    // Create directory structure.
    create_directories(&home)?;

    // Detect environment.
    let detected = if bare {
        output::info("Bare mode — skipping environment detection.");
        DetectedEnv::default()
    } else {
        detect_environment()
    };

    // Detect installed platforms.
    let platforms = detect_platforms();
    if platforms.is_empty() {
        output::warn("No supported AI coding platforms detected.");
        output::info("You can add one later with `locus platform add <platform>`.");
    } else {
        for p in &platforms {
            output::success(&format!("Detected {}", p.display_name()));
        }
    }

    // Generate default config.
    let config = build_default_config(platforms, &detected);
    let yaml = config.to_yaml()?;
    fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write config: {}", e),
        path: config_path.clone(),
    })?;
    output::success(&format!("Created {}", config_path.display()));

    // Summary.
    output::section("Ready");
    output::info(&format!("Home:   {}", home.display()));
    output::info(&format!("Data:   {}", home.join("data").display()));
    output::info(&format!("Config: {}", config_path.display()));
    println!();
    output::info("Next steps:");
    if config.platforms.is_empty() {
        output::info("  locus platform add opencode   Add a platform adapter");
    }
    output::info("  locus doctor                  Validate installation");
    println!();

    Ok(())
}

/// Resolve the Locus home directory.
fn resolve_locus_home() -> Result<PathBuf, LocusError> {
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

/// Create the Locus directory structure and install content.
fn create_directories(home: &PathBuf) -> Result<(), LocusError> {
    let dirs = [
        home.to_path_buf(),
        home.join("algorithm"),
        home.join("skills"),
        home.join("agents"),
        home.join("protocols"),
        home.join("data"),
        home.join("data/memory"),
        home.join("data/memory/work"),
        home.join("data/memory/learning"),
        home.join("data/memory/research"),
        home.join("data/memory/state"),
        home.join("data/projects"),
        home.join("data/context-packs"),
        home.join("data/skill-customizations"),
    ];

    for dir in &dirs {
        fs::create_dir_all(dir).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to create directory: {}", e),
            path: dir.clone(),
        })?;
    }

    // Install bundled content (algorithm, skills, agents, protocols).
    install_bundled_content(home)?;

    output::success(&format!(
        "Created directory structure at {}",
        home.display()
    ));
    Ok(())
}

/// Install the bundled algorithm, skills, agents, and protocols.
///
/// Content is embedded at compile time from the repo source directories.
fn install_bundled_content(home: &PathBuf) -> Result<(), LocusError> {
    for (relative_path, content) in crate::bundled::bundled_files() {
        if relative_path == "scripts/statusline.sh" {
            write_bundled_executable(home, &relative_path, content)?;
        } else {
            write_bundled(home, &relative_path, content)?;
        }
    }

    Ok(())
}

/// Write a bundled file to the Locus home directory.
fn write_bundled(home: &PathBuf, relative_path: &str, content: &str) -> Result<(), LocusError> {
    let target = home.join(relative_path);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to create directory: {}", e),
            path: parent.to_path_buf(),
        })?;
    }
    fs::write(&target, content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write file: {}", e),
        path: target,
    })
}

/// Write a bundled file and chmod +x it (Unix only).
fn write_bundled_executable(
    home: &PathBuf,
    relative_path: &str,
    content: &str,
) -> Result<(), LocusError> {
    write_bundled(home, relative_path, content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let target = home.join(relative_path);
        if let Ok(meta) = fs::metadata(&target) {
            let mut perms = meta.permissions();
            perms.set_mode(0o755);
            let _ = fs::set_permissions(&target, perms);
        }
    }
    Ok(())
}

/// Detected environment information.
#[derive(Default)]
#[allow(dead_code)]
struct DetectedEnv {
    shell: Option<String>,
    editor: Option<String>,
    git_user: Option<String>,
    git_email: Option<String>,
}

/// Detect the user's development environment.
fn detect_environment() -> DetectedEnv {
    let shell = std::env::var("SHELL").ok().map(|s| {
        // Extract just the shell name from the path.
        s.rsplit('/').next().unwrap_or(&s).to_string()
    });

    let editor = std::env::var("EDITOR")
        .or_else(|_| std::env::var("VISUAL"))
        .ok();

    let git_user = std::process::Command::new("git")
        .args(["config", "--global", "user.name"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        });

    let git_email = std::process::Command::new("git")
        .args(["config", "--global", "user.email"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        });

    if let Some(ref shell) = shell {
        output::info(&format!("Shell:  {}", shell));
    }
    if let Some(ref editor) = editor {
        output::info(&format!("Editor: {}", editor));
    }
    if let Some(ref user) = git_user {
        output::info(&format!("Git:    {}", user));
    }

    DetectedEnv {
        shell,
        editor,
        git_user,
        git_email,
    }
}

/// Detect which supported platforms are installed.
fn detect_platforms() -> Vec<Platform> {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return Vec::new(),
    };

    let mut found = Vec::new();
    for platform in Platform::all() {
        let config_dir = home.join(platform.config_dir_name());
        if config_dir.exists() {
            // Also check if the CLI binary is available.
            let cli_available = std::process::Command::new("which")
                .arg(platform.cli_command())
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);

            if cli_available {
                found.push(*platform);
            }
        }
    }

    found
}

/// Build a default LocusConfig from detected environment.
fn build_default_config(platforms: Vec<Platform>, _env: &DetectedEnv) -> LocusConfig {
    LocusConfig {
        platforms,
        algorithm: AlgorithmConfig::default(),
        skills: SkillConfig::default(),
        notifications: NotificationConfig::default(),
        inference: InferenceConfig::default(),
        paths: PathConfig::default(),
        platform_overrides: std::collections::HashMap::new(),
        delegation: locus_core::DelegationConfig::default(),
    }
}
