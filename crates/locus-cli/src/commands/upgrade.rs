//! `locus upgrade` — check for and install updates from GitHub releases.

use locus_core::LocusError;

use crate::output;

/// Run the upgrade command.
pub fn run(check_only: bool) -> Result<(), LocusError> {
    output::print_header();
    output::section("Upgrade");

    let current_version = env!("CARGO_PKG_VERSION");
    output::info(&format!("Current version: {}", current_version));

    // Check for latest release on GitHub
    let status = check_for_update()?;

    match status {
        UpdateStatus::NoReleases => {
            output::info("No releases available yet");
            output::info("This project hasn't published any releases on GitHub");
            return Ok(());
        }
        UpdateStatus::UpToDate => {
            output::success("Already up to date");
            return Ok(());
        }
        UpdateStatus::UpdateAvailable { latest_version } => {
            output::info(&format!("Latest version: {}", latest_version));
            
            if check_only {
                output::info("Update available (use `locus upgrade` to install)");
                return Ok(());
            }

            output::section("Installing update");
            install_update(&latest_version)?;
            output::success(&format!("Upgraded to version {}", latest_version));
            output::info("Restart any running locus processes to use the new version");
        }
    }

    Ok(())
}

enum UpdateStatus {
    NoReleases,
    UpToDate,
    UpdateAvailable { latest_version: String },
}

fn check_for_update() -> Result<UpdateStatus, LocusError> {
    const REPO_OWNER: &str = "devergehq";
    const REPO_NAME: &str = "locus";

    let current_version = env!("CARGO_PKG_VERSION");

    // Query GitHub API for latest release
    let releases = self_update::backends::github::ReleaseList::configure()
        .repo_owner(REPO_OWNER)
        .repo_name(REPO_NAME)
        .build()
        .map_err(|e| LocusError::Upgrade {
            message: format!("Failed to configure GitHub release check: {}", e),
        })?;

    let latest_release = match releases.fetch() {
        Ok(releases) => {
            if releases.is_empty() {
                return Ok(UpdateStatus::NoReleases);
            }
            releases[0].clone()
        }
        Err(e) => {
            // Check if it's a 404 (no releases)
            let err_str = e.to_string();
            if err_str.contains("404") || err_str.contains("Not Found") {
                return Ok(UpdateStatus::NoReleases);
            }
            return Err(LocusError::Upgrade {
                message: format!("Failed to fetch releases from GitHub: {}", e),
            });
        }
    };

    // Extract version from tag (remove leading 'v' if present)
    let latest_version = latest_release.version.trim_start_matches('v');

    // Compare versions
    if version_compare(current_version, latest_version)? {
        Ok(UpdateStatus::UpToDate)
    } else {
        Ok(UpdateStatus::UpdateAvailable {
            latest_version: latest_version.to_string(),
        })
    }
}

fn version_compare(current: &str, latest: &str) -> Result<bool, LocusError> {
    // Simple semver comparison: current >= latest means up to date
    // For now, just do string comparison (will upgrade to semver crate if needed)
    
    let parse_version = |v: &str| -> Result<(u32, u32, u32), LocusError> {
        let parts: Vec<&str> = v.split('.').collect();
        if parts.len() != 3 {
            return Err(LocusError::Upgrade {
                message: format!("Invalid version format: {}", v),
            });
        }
        Ok((
            parts[0].parse().map_err(|_| LocusError::Upgrade {
                message: format!("Invalid version number: {}", v),
            })?,
            parts[1].parse().map_err(|_| LocusError::Upgrade {
                message: format!("Invalid version number: {}", v),
            })?,
            parts[2].parse().map_err(|_| LocusError::Upgrade {
                message: format!("Invalid version number: {}", v),
            })?,
        ))
    };

    let current_parsed = parse_version(current)?;
    let latest_parsed = parse_version(latest)?;

    Ok(current_parsed >= latest_parsed)
}

fn install_update(version: &str) -> Result<(), LocusError> {
    const REPO_OWNER: &str = "devergehq";
    const REPO_NAME: &str = "locus";
    const BIN_NAME: &str = "locus";

    let target = self_update::get_target();
    
    output::info(&format!("Downloading {} for {}", version, target));

    let update = self_update::backends::github::Update::configure()
        .repo_owner(REPO_OWNER)
        .repo_name(REPO_NAME)
        .bin_name(BIN_NAME)
        .target(&target)
        .current_version(env!("CARGO_PKG_VERSION"))
        .build()
        .map_err(|e| LocusError::Upgrade {
            message: format!("Failed to configure update: {}", e),
        })?;

    let status = update.update().map_err(|e| {
        // Check for permission errors
        let err_str = e.to_string();
        if err_str.contains("Permission denied") || err_str.contains("permission") {
            LocusError::Upgrade {
                message: format!(
                    "Permission denied while updating binary.\n\
                     The binary might be installed in a system directory.\n\
                     Try running with sudo: sudo locus upgrade"
                ),
            }
        } else if err_str.contains("404") || err_str.contains("Not Found") {
            LocusError::Upgrade {
                message: format!(
                    "Release assets not found for {}.\n\
                     This platform ({}) might not have pre-built binaries yet.\n\
                     You may need to build from source.",
                    version, target
                ),
            }
        } else {
            LocusError::Upgrade {
                message: format!("Failed to download and install update: {}", e),
            }
        }
    })?;

    match status {
        self_update::Status::UpToDate(_) => {
            // Shouldn't happen since we already checked, but handle it
            Ok(())
        }
        self_update::Status::Updated(_) => {
            output::info("Binary replaced successfully");
            Ok(())
        }
    }
}
