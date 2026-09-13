//! `locus doctor` — validate the Locus installation.

use std::path::{Path, PathBuf};

use locus_core::config::LocusConfig;
use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::commands::health::{self, HealthEnv, Severity};
use crate::commands::update_content;
use crate::output;

/// What doctor concluded, and what the process should exit with.
///
/// The three states are distinct on purpose. Before DEV-506 doctor always
/// returned success, so no script could act on its verdict and no defect it
/// found could stop anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DoctorOutcome {
    pub issues: usize,
    pub warnings: usize,
}

impl DoctorOutcome {
    /// `0` clean, `1` degrading, `2` broken.
    ///
    /// Warnings are deliberately non-zero: a warning that cannot fail a check
    /// is the exact failure mode DEV-506 exists to remove. They are kept
    /// distinct from errors so a caller can choose to tolerate one and not the
    /// other.
    pub fn exit_code(&self) -> i32 {
        if self.issues > 0 {
            2
        } else if self.warnings > 0 {
            1
        } else {
            0
        }
    }
}

/// Run the doctor command.
pub fn run() -> Result<DoctorOutcome, LocusError> {
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

    // 5. Check content staleness.
    output::section("Content");
    match update_content::check_staleness(&home) {
        Ok(update_content::StalenessReport::MissingManifest) => {
            output::warn("Content manifest missing. Run `locus update-content`.");
            warnings.push("Content manifest missing. Run `locus update-content`.".into());
        }
        Ok(update_content::StalenessReport::UpToDate) => {
            output::success("Content is up to date");
        }
        Ok(update_content::StalenessReport::Stale(files)) => {
            output::warn(&format!("{} content file(s) are stale", files.len()));
            for f in &files {
                output::warn(&format!("  outdated: {}", f));
            }
            warnings.push(format!(
                "{} content file(s) stale. Run `locus update-content`.",
                files.len()
            ));
        }
        Err(e) => {
            output::warn(&format!("Could not check content staleness: {}", e));
            warnings.push(format!("Content staleness check failed: {}", e));
        }
    }

    let superseded = update_content::superseded_algorithm_versions(&home);
    if superseded.is_empty() {
        output::success(&format!(
            "Algorithm — {} is the only spec installed",
            locus_core::ALGORITHM_FILE
        ));
    } else {
        for name in &superseded {
            output::warn(&format!(
                "  superseded Algorithm spec still installed: {} (current is {})",
                name,
                locus_core::ALGORITHM_FILE
            ));
        }
        warnings.push(format!(
            "{} superseded Algorithm spec(s) installed. Run `locus update-content`.",
            superseded.len()
        ));
    }

    let platform_config_warnings = update_content::check_platform_configs(&home);
    for w in &platform_config_warnings {
        output::warn(w);
        warnings.push(w.clone());
    }

    // 6. Check platforms.
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
    check_plugin_binary_reachable(&mut issues);

    // 6b. Delegation vehicles — informational, always.
    //
    // Neither of these can fail a check, and that is deliberate rather than an
    // oversight. Allele is a separate product with its own install; a machine
    // without it is a supported configuration, not a defect, and reporting it
    // as a warning would be a warning nobody can act on, on a machine where
    // nothing is wrong. Reported at all because the routing depends on it:
    // which vehicle delegation reaches for is not obvious from the outside,
    // and when native subagents are permitted the user should be able to find
    // out why without reading the hook.
    output::section("Delegation Vehicles");
    for line in locus_core::vehicles::VehicleAvailability::probe().doctor_lines() {
        output::info(&line);
    }

    // 7. State checks — the ones that can report a problem with something that
    // exists, rather than only with something that is missing.
    output::section("Health");
    let findings = health::check_all(&build_health_env(&data_dir));
    if findings.is_empty() {
        output::success("No degradation detected");
    } else {
        for finding in &findings {
            match finding.severity {
                Severity::Error => {
                    output::error(&finding.message);
                    issues.push(finding.message.clone());
                }
                Severity::Warning => {
                    output::warn(&finding.message);
                    warnings.push(finding.message.clone());
                }
            }
        }
    }

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
        output::info(match (issues.is_empty(), warnings.is_empty()) {
            (false, _) => "Exit 2 — something is broken.",
            (true, false) => "Exit 1 — nothing is broken yet.",
            _ => "Exit 0.",
        });
    }

    println!();
    Ok(DoctorOutcome {
        issues: issues.len(),
        warnings: warnings.len(),
    })
}

/// Assemble what the state checks read from the live machine.
///
/// This is the only place in the health path that touches the real
/// filesystem or spawns a process; everything in [`health`] is a pure function
/// over what this returns.
fn build_health_env(data_dir: &Path) -> HealthEnv {
    let delegation_roots = [
        data_dir.join("delegations"),
        data_dir.join("memory").join("work").join("delegations"),
    ]
    .into_iter()
    .filter(|p| p.exists())
    .collect();

    let locus_on_path = locus_binaries_on_path();

    HealthEnv {
        data_dir: data_dir.to_path_buf(),
        delegation_roots,
        opencode_auth: canonical_opencode_auth().filter(|p| p.exists()),
        locus_on_path_version: locus_version_on_path(),
        locus_on_path,
        running_version: env!("CARGO_PKG_VERSION").to_string(),
        now: std::time::SystemTime::now(),
    }
}

/// Where OpenCode keeps the credential the delegation path depends on.
///
/// OpenCode resolves it as `$XDG_DATA_HOME/opencode/auth.json`, falling back to
/// `~/.local/share/opencode/auth.json`.
///
/// Resolved here rather than imported from the OpenCode adapter deliberately:
/// `locus-adapter-opencode` gains an equivalent `canonical_auth_path` in the
/// DEV-505 work, which is a separate open PR. Duplicating ten lines keeps this
/// change mergeable in either order instead of stacking it behind that one. See
/// DEV-612 to collapse the two once DEV-505 has landed.
/// Both candidates are probed, in order, and the first that exists wins —
/// because the rest of the stack does not agree on the answer.
/// `locus-adapter-opencode::run::seed_opencode_auth` hardcodes
/// `~/.local/share/opencode/auth.json` and ignores `XDG_DATA_HOME`, contradicting
/// its own doc comment. Honouring only the variable would leave both credential
/// checks silently disabled for anyone who sets it, while the adapter carried on
/// writing somewhere else. Checking both is correct under either behaviour, and
/// stays correct when the adapter is fixed. Tracked as DEV-614.
fn canonical_opencode_auth() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = std::env::var_os("XDG_DATA_HOME") {
        if !dir.is_empty() {
            candidates.push(PathBuf::from(dir).join("opencode").join("auth.json"));
        }
    }
    if let Some(home) = dirs::home_dir() {
        candidates.push(
            home.join(".local")
                .join("share")
                .join("opencode")
                .join("auth.json"),
        );
    }
    candidates
        .iter()
        .find(|p| p.exists())
        .cloned()
        .or_else(|| candidates.into_iter().next())
}

/// Every `locus` the PATH resolves to, in PATH order.
///
/// `which -a` rather than `which`: one binary is the healthy case, and the
/// interesting condition is the second one, which the plugin's hooks will never
/// invoke no matter how carefully the user upgrades it.
fn locus_binaries_on_path() -> Vec<PathBuf> {
    let Ok(output) = std::process::Command::new("which")
        .args(["-a", "locus"])
        .output()
    else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    let mut seen: Vec<PathBuf> = Vec::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let path = PathBuf::from(line.trim());
        if !line.trim().is_empty() && !seen.contains(&path) {
            seen.push(path);
        }
    }
    seen
}

/// The version of the `locus` binary the plugin's hooks will actually invoke.
fn locus_version_on_path() -> Option<String> {
    let output = std::process::Command::new("locus")
        .arg("--version")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    // `locus 0.2.1` -> `0.2.1`
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .last()
        .map(|s| s.to_string())
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
    // CLAUDE.md is no longer generated — the plugin supplies the directive. A
    // CLAUDE.md here is the user's own file, so its absence is not a finding.
    let claude_md = config_dir.join("CLAUDE.md");
    if let Ok(content) = std::fs::read_to_string(&claude_md) {
        if content.contains("# Locus") {
            output::warn("Claude Code CLAUDE.md still carries generated Locus content");
            warnings.push(
                "~/.claude/CLAUDE.md holds generated Locus content the plugin now supplies. Run `locus platform remove claude-code` to clear it."
                    .into(),
            );
        }
    }

    let settings = config_dir.join("settings.json");
    if let Ok(content) = std::fs::read_to_string(&settings) {
        if content.contains("locus hook ") {
            output::warn("Claude Code settings.json still registers `locus hook` entries");
            warnings.push(
                "settings.json registers `locus hook` entries the plugin now supplies, so hooks may fire twice. Run `locus platform remove claude-code`."
                    .into(),
            );
        }
        if content.contains("scripts/statusline.sh") {
            output::success("Claude Code statusLine — Locus script wired");
        } else {
            output::warn("Claude Code statusLine — Locus script not configured");
            warnings.push(
                "settings.json statusLine not set to Locus. Re-run `locus platform add claude-code`."
                    .into(),
            );
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

/// A Locus plugin with no `locus` on PATH is a broken install, not a
/// configuration.
///
/// The plugin's hooks all shell out to the binary. If it is not resolvable from
/// a hook's environment, every hook is inert: the Algorithm is not enforced, the
/// Stop gate never fires, and the activation log stays empty — while everything
/// still *looks* fine. That is the failure this whole workstream keeps meeting,
/// so doctor treats it as an error rather than a warning.
///
/// Note the asymmetry: `locus doctor` is itself the binary, so reaching this
/// code proves it exists. What it does not prove is that it is on PATH — it may
/// have been invoked by absolute path — which is the thing hooks actually need.
fn check_plugin_binary_reachable(issues: &mut Vec<String>) {
    let Some(config_dir) = dirs::home_dir().map(|h| h.join(".claude")) else {
        return;
    };
    let installed = plugin_is_installed(&config_dir);
    if !installed {
        return;
    }

    let on_path = std::process::Command::new("which")
        .arg("locus")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if on_path {
        output::success("Locus plugin — binary reachable on PATH");
    } else {
        output::error("Locus plugin — installed, but `locus` is not on PATH");
        issues.push(
            "The Locus plugin is installed but `locus` is not on PATH. Every plugin \
             hook is inert until it is: the Algorithm is not enforced and the \
             activation log is not written. Put the binary on PATH and restart \
             Claude Code."
                .into(),
        );
    }
}

/// Detect an installed Locus plugin without depending on Claude Code internals
/// beyond the directory layout it already publishes.
fn plugin_is_installed(config_dir: &Path) -> bool {
    let cache = config_dir.join("plugins");
    if !cache.exists() {
        return false;
    }
    let mut stack: Vec<PathBuf> = vec![cache];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                // Only descend a couple of levels; the marketplace cache nests
                // as plugins/cache/<marketplace>/<plugin>/.
                if path.components().count() < dir.components().count() + 4 {
                    stack.push(path);
                }
            } else if path.file_name().and_then(|n| n.to_str()) == Some("plugin.json") {
                if let Ok(text) = std::fs::read_to_string(&path) {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                        if v.get("name").and_then(|n| n.as_str()) == Some("locus") {
                            return true;
                        }
                    }
                }
            }
        }
    }
    false
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
