//! `locus update-content` — sync bundled files from binary to ~/.locus/.
//!
//! Compares SHA-256 hashes of embedded content against installed files,
//! overwrites any that differ, and tracks state in a manifest.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use locus_core::platform::Platform;
use locus_core::LocusError;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::output;

/// Content manifest tracking what the binary last wrote.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct ContentManifest {
    pub version: String,
    pub updated_at: String,
    pub files: HashMap<String, String>,
}

/// Result of a staleness check.
pub enum StalenessReport {
    /// No manifest found.
    MissingManifest,
    /// All installed files match embedded content.
    UpToDate,
    /// Some installed files differ from embedded content.
    Stale(Vec<String>),
}

/// Run the update-content command.
pub fn run(skip_platforms: bool) -> Result<(), LocusError> {
    output::print_header();
    output::section("Updating Content");

    let home = resolve_locus_home()?;
    run_at(&home, skip_platforms)
}

/// The body of `update-content`, against an explicit Locus home.
///
/// Split out so the **real command path** is testable. The previous prune bug
/// shipped because its test called the prune helper directly against a
/// directory the test itself built — which verifies the helper and cannot
/// detect that nothing on the real path invokes it.
pub fn run_at(home: &Path, skip_platforms: bool) -> Result<(), LocusError> {
    let bundled = crate::bundled::bundled_files();
    let mut updated = 0usize;
    let mut up_to_date = 0usize;
    let mut manifest_files: HashMap<String, String> = HashMap::new();

    for (relative_path, content) in bundled {
        // Never touch user data directories.
        if relative_path.starts_with("data/")
            || relative_path.starts_with("context-packs/")
            || relative_path.starts_with("skill-customizations/")
        {
            continue;
        }

        let target = home.join(&relative_path);
        let embedded_hash = compute_hash(content);

        let needs_update = if target.exists() {
            match fs::read_to_string(&target) {
                Ok(installed) => compute_hash(&installed) != embedded_hash,
                Err(_) => true,
            }
        } else {
            true
        };

        if needs_update {
            if relative_path == "scripts/statusline.sh" {
                write_bundled_executable(home, &relative_path, content)?;
            } else {
                write_bundled(home, &relative_path, content)?;
            }
            updated += 1;
            output::success(&format!("Updated {}", relative_path));
        } else {
            up_to_date += 1;
        }

        manifest_files.insert(relative_path, format!("sha256:{}", embedded_hash));
    }

    // Write manifest.
    let manifest = ContentManifest {
        version: env!("CARGO_PKG_VERSION").to_string(),
        updated_at: chrono::Utc::now().to_rfc3339(),
        files: manifest_files,
    };
    let manifest_path = home.join(".locus-content-manifest.json");
    let manifest_json =
        serde_json::to_string_pretty(&manifest).map_err(|e| LocusError::Config {
            message: format!("Failed to serialize manifest: {}", e),
            path: Some(manifest_path.clone()),
        })?;
    fs::write(&manifest_path, manifest_json).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write manifest: {}", e),
        path: manifest_path.clone(),
    })?;

    output::info(&format!(
        "{} file(s) updated, {} file(s) up to date",
        updated, up_to_date
    ));

    prune_superseded_algorithm_versions(home)?;

    if !skip_platforms {
        output::section("Platform Configs");
        regenerate_platform_configs(home)?;
    }

    println!();
    Ok(())
}

/// Remove Algorithm specs from a previous version.
///
/// Content sync writes files and never removes them, so without this an upgrade
/// leaves the old spec beside the new one — two Algorithm documents, only one
/// referenced by anything, and the stale one exactly the sort of file a human or
/// a session opens and believes.
///
/// Lives here rather than in `init` because this is the command that actually
/// runs on an upgrade: `init` returns early once Locus is initialised, so a
/// prune wired only into `init` can never fire on an install that has something
/// stale to remove. That was the v0.2.0 bug.
///
/// Deliberately narrow: `algorithm/*.md` only, and only files this build does
/// not bundle. Not a general sweep of the Locus home, because the other managed
/// directories are places users legitimately add their own content.
pub fn prune_superseded_algorithm_versions(home: &Path) -> Result<(), LocusError> {
    let dir = home.join("algorithm");

    let Ok(entries) = fs::read_dir(&dir) else {
        return Ok(());
    };

    let bundled: Vec<String> = crate::bundled::bundled_files()
        .into_iter()
        .map(|(rel, _)| rel)
        .collect();

    for entry in entries.flatten() {
        let path = entry.path();
        if !path.extension().is_some_and(|x| x == "md") {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if bundled.contains(&format!("algorithm/{name}")) {
            continue;
        }

        fs::remove_file(&path).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to remove superseded Algorithm spec: {}", e),
            path: path.clone(),
        })?;
        output::success(&format!(
            "Removed superseded Algorithm spec: {name} (now {})",
            locus_core::ALGORITHM_FILE
        ));
    }

    Ok(())
}

/// Check whether installed content is stale relative to the embedded binary content.
pub fn check_staleness(home: &Path) -> Result<StalenessReport, LocusError> {
    let manifest_path = home.join(".locus-content-manifest.json");
    if !manifest_path.exists() {
        return Ok(StalenessReport::MissingManifest);
    }

    let bundled = crate::bundled::bundled_files();
    let mut outdated = Vec::new();

    for (relative_path, content) in bundled {
        let target = home.join(&relative_path);
        let embedded_hash = compute_hash(content);

        let is_stale = if target.exists() {
            match fs::read_to_string(&target) {
                Ok(installed) => compute_hash(&installed) != embedded_hash,
                Err(_) => true,
            }
        } else {
            true
        };

        if is_stale {
            outdated.push(relative_path);
        }
    }

    if outdated.is_empty() {
        Ok(StalenessReport::UpToDate)
    } else {
        Ok(StalenessReport::Stale(outdated))
    }
}

/// Algorithm specs installed that this build no longer bundles.
///
/// Surfaced by `doctor` so a superseded spec is visible without anyone reading
/// the directory by hand — which is how the v0.2.0 prune bug was found.
pub fn superseded_algorithm_versions(home: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(home.join("algorithm")) else {
        return Vec::new();
    };

    let bundled: Vec<String> = crate::bundled::bundled_files()
        .into_iter()
        .map(|(rel, _)| rel)
        .collect();

    let mut stale: Vec<String> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == "md"))
        .filter_map(|p| p.file_name()?.to_str().map(str::to_string))
        .filter(|n| !bundled.contains(&format!("algorithm/{n}")))
        .collect();

    stale.sort();
    stale
}

/// Check whether platform config files exist for configured platforms.
pub fn check_platform_configs(home: &Path) -> Vec<String> {
    let mut warnings = Vec::new();

    let config_path = home.join("locus.yaml");
    let config = match locus_core::config::LocusConfig::from_file(&config_path) {
        Ok(c) => c,
        Err(_) => return warnings,
    };

    let user_home = match dirs::home_dir() {
        Some(h) => h,
        None => return warnings,
    };

    for platform in &config.platforms {
        match platform {
            Platform::OpenCode => {
                let config_dir = user_home.join(".config").join("opencode");
                if !config_dir.join("AGENTS.md").exists() {
                    warnings.push(format!(
                        "OpenCode AGENTS.md missing. Run `locus platform add opencode`."
                    ));
                }
                if !config_dir.join("opencode.json").exists() {
                    warnings.push(format!(
                        "OpenCode opencode.json missing. Run `locus platform add opencode`."
                    ));
                }
            }
            Platform::ClaudeCode => {
                let config_dir = user_home.join(".claude");
                if !config_dir.join("CLAUDE.md").exists() {
                    warnings.push(format!(
                        "Claude Code CLAUDE.md missing. Run `locus platform add claude-code`."
                    ));
                }
                if !config_dir.join("settings.json").exists() {
                    warnings.push(format!(
                        "Claude Code settings.json missing. Run `locus platform add claude-code`."
                    ));
                }
            }
            _ => {}
        }
    }

    warnings
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn compute_hash(content: &str) -> String {
    let digest = Sha256::digest(content.as_bytes());
    format!("{:x}", digest)
}

fn write_bundled(home: &Path, relative_path: &str, content: &str) -> Result<(), LocusError> {
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

fn write_bundled_executable(
    home: &Path,
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

fn regenerate_platform_configs(home: &Path) -> Result<(), LocusError> {
    let config_path = home.join("locus.yaml");
    if !config_path.exists() {
        output::warn("locus.yaml not found, skipping platform config regeneration");
        return Ok(());
    }

    let config = locus_core::config::LocusConfig::from_file(&config_path)?;
    if config.platforms.is_empty() {
        output::info("No platforms configured, skipping platform config regeneration");
        return Ok(());
    }

    for platform in &config.platforms {
        match platform {
            Platform::OpenCode => {
                let adapter = locus_adapter_opencode::OpenCodeAdapter::new();
                adapter.setup(home)?;
                output::success("Regenerated OpenCode platform config");
            }
            Platform::ClaudeCode => {
                let adapter = locus_adapter_claude::ClaudeAdapter::new();
                adapter.setup(home)?;
                output::success("Regenerated Claude Code platform config");
            }
            _ => {
                output::info(&format!(
                    "No adapter available for {}",
                    platform.display_name()
                ));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The v0.2.0 bug, as a test.
    ///
    /// This drives `run_at` — the actual body of `locus update-content` — rather
    /// than calling the prune helper directly. The shipped tests did the latter,
    /// which passed while nothing on the real path invoked the prune at all.
    #[test]
    fn update_content_removes_a_superseded_algorithm_spec() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let alg = home.join("algorithm");
        fs::create_dir_all(&alg).unwrap();

        // Simulate the state a real upgrade leaves behind.
        fs::write(alg.join("v1.1.md"), "superseded spec").unwrap();

        run_at(home, true).expect("update-content");

        assert!(
            !alg.join("v1.1.md").exists(),
            "superseded spec survived `locus update-content` — the prune is not \
             wired into the path users actually run"
        );
        assert!(
            alg.join(locus_core::ALGORITHM_FILE).exists(),
            "current spec was not installed"
        );
    }

    #[test]
    fn update_content_installs_bundled_content() {
        let tmp = tempfile::tempdir().unwrap();
        run_at(tmp.path(), true).expect("update-content");

        assert!(tmp.path().join("protocols/orchestration.md").exists());
        assert!(tmp.path().join("skills/delegation/SKILL.md").exists());
        assert!(tmp
            .path()
            .join("algorithm")
            .join(locus_core::ALGORITHM_FILE)
            .exists());
    }

    #[test]
    fn prune_keeps_the_current_spec() {
        let tmp = tempfile::tempdir().unwrap();
        let alg = tmp.path().join("algorithm");
        fs::create_dir_all(&alg).unwrap();
        fs::write(alg.join(locus_core::ALGORITHM_FILE), "current").unwrap();

        prune_superseded_algorithm_versions(tmp.path()).unwrap();

        assert!(alg.join(locus_core::ALGORITHM_FILE).exists());
    }

    /// Scoped to Algorithm specs. Anything else in that directory is the user's.
    #[test]
    fn prune_leaves_other_files_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let alg = tmp.path().join("algorithm");
        fs::create_dir_all(&alg).unwrap();
        fs::write(alg.join("notes.txt"), "mine").unwrap();
        fs::write(tmp.path().join("stray.md"), "mine too").unwrap();

        prune_superseded_algorithm_versions(tmp.path()).unwrap();

        assert!(alg.join("notes.txt").exists(), "pruned a non-spec file");
        assert!(tmp.path().join("stray.md").exists(), "pruned outside algorithm/");
    }

    #[test]
    fn prune_without_an_algorithm_directory_is_not_an_error() {
        let tmp = tempfile::tempdir().unwrap();
        prune_superseded_algorithm_versions(tmp.path()).unwrap();
    }
}
