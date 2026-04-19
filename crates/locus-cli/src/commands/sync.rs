//! `locus sync` — synchronise user data between machines via git.

use std::path::PathBuf;
use std::process::Command;

use locus_core::LocusError;

use crate::output;

/// Run the sync command.
pub fn run(init_remote: Option<String>) -> Result<(), LocusError> {
    output::print_header();

    let data_dir = resolve_data_dir()?;

    // If --init is passed, initialize the data dir as a git repo.
    if let Some(remote) = init_remote {
        return init_data_repo(&data_dir, &remote);
    }

    // Check if data dir is a git repo.
    if !data_dir.join(".git").exists() {
        output::error("Data directory is not a git repository.");
        output::info("Initialize with: locus sync --init <remote-url>");
        output::info(&format!(
            "  e.g. locus sync --init git@github.com:you/locus-data.git"
        ));
        return Ok(());
    }

    output::section("Syncing user data");

    // Pull first (get remote changes).
    output::info("Pulling remote changes...");
    let pull_result = git(&data_dir, &["pull", "--rebase", "--autostash"])?;
    if pull_result.success {
        output::success("Pull complete.");
    } else if pull_result.output.contains("no tracking information") {
        output::warn("No upstream branch set. Push will set it.");
    } else {
        output::warn(&format!("Pull: {}", pull_result.output.trim()));
    }

    // Stage all changes.
    git(&data_dir, &["add", "-A"])?;

    // Check if there's anything to commit.
    let status = git(&data_dir, &["status", "--porcelain"])?;
    if status.output.trim().is_empty() {
        output::info("No local changes to sync.");
    } else {
        // Commit with auto-generated message.
        let timestamp = chrono_timestamp();
        let message = format!("locus sync: {}", timestamp);
        git(&data_dir, &["commit", "-m", &message])?;
        output::success("Committed local changes.");

        // Push.
        output::info("Pushing to remote...");
        let push_result = git(&data_dir, &["push", "-u", "origin", "HEAD"])?;
        if push_result.success {
            output::success("Push complete.");
        } else {
            output::warn(&format!("Push: {}", push_result.output.trim()));
        }
    }

    output::section("Done");
    println!();
    Ok(())
}

/// Initialize the data directory as a git repo with a remote.
fn init_data_repo(data_dir: &PathBuf, remote: &str) -> Result<(), LocusError> {
    output::section("Initializing data repository");

    if data_dir.join(".git").exists() {
        output::info("Data directory is already a git repository.");
        // Just update the remote.
        git(data_dir, &["remote", "set-url", "origin", remote])?;
        output::success(&format!("Updated remote to: {}", remote));
        return Ok(());
    }

    // Initialize git repo.
    git(data_dir, &["init"])?;
    output::success("Initialized git repository.");

    // Add remote.
    git(data_dir, &["remote", "add", "origin", remote])?;
    output::success(&format!("Added remote: {}", remote));

    // Create .gitignore for ephemeral state.
    let gitignore_path = data_dir.join(".gitignore");
    std::fs::write(
        &gitignore_path,
        "# Ephemeral state — machine-local, not synced\nmemory/state/\n",
    )
    .map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write .gitignore: {}", e),
        path: gitignore_path,
    })?;
    output::success("Created .gitignore (excludes memory/state/).");

    // Initial commit.
    git(data_dir, &["add", "-A"])?;
    git(data_dir, &["commit", "-m", "Initial locus data repository"])?;
    output::success("Created initial commit.");

    output::info("Push with: locus sync");
    println!();
    Ok(())
}

/// Run a git command in the given directory.
fn git(dir: &PathBuf, args: &[&str]) -> Result<GitResult, LocusError> {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .map_err(|e| LocusError::Sync {
            message: format!("Failed to run git: {}", e),
        })?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let combined = if stderr.is_empty() {
        stdout.clone()
    } else {
        format!("{}{}", stdout, stderr)
    };

    Ok(GitResult {
        success: output.status.success(),
        output: combined,
    })
}

struct GitResult {
    success: bool,
    output: String,
}

/// Generate a timestamp string for commit messages.
fn chrono_timestamp() -> String {
    // Use git's own date formatting to avoid adding chrono dependency.
    Command::new("date")
        .args(["+%Y-%m-%d %H:%M:%S"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

/// Resolve the data directory.
fn resolve_data_dir() -> Result<PathBuf, LocusError> {
    if let Ok(data_home) = std::env::var("LOCUS_DATA_HOME") {
        return Ok(PathBuf::from(data_home));
    }

    let locus_home = if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        PathBuf::from(env_home)
    } else {
        dirs::home_dir()
            .map(|h| h.join(".locus"))
            .ok_or_else(|| LocusError::Config {
                message: "Could not determine home directory".into(),
                path: None,
            })?
    };

    // Try loading config for data path override.
    let config_path = locus_home.join("locus.yaml");
    if config_path.exists() {
        if let Ok(config) = locus_core::config::LocusConfig::from_file(&config_path) {
            return config.resolve_data_dir();
        }
    }

    Ok(locus_home.join("data"))
}
