//! Health checks for `locus doctor` — the ones that can actually fail.
//!
//! Doctor could always emit warnings. What it could not do was notice anything
//! wrong with something that exists: its checks asked "is this directory
//! present?", "does this config key appear?", "does settings.json mention
//! `locus hook`?". Every one of those passed on a machine that was
//! simultaneously running seven double-registered hooks, holding 231
//! delegation sandboxes with 67 stray credential copies, and carrying an
//! OpenCode credential that had expired five weeks earlier.
//!
//! These checks look at the *state* of things that exist. Each one is a pure
//! function over an explicitly supplied environment, so an unhealthy fixture
//! can be built in a temp directory and asserted against — see the tests at
//! the bottom of this file.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use locus_adapter_claude::config_gen::is_locus_hook_command;

/// How bad a finding is.
///
/// The distinction drives the exit code, so it has to mean something:
/// `Error` is broken — something the user asked for is not working. `Warning`
/// is degrading — it works now and will not keep working.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    /// Degrading. Worth fixing; nothing is broken yet.
    Warning,
    /// Broken. Something does not work.
    Error,
}

/// One thing doctor found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub severity: Severity,
    pub message: String,
}

impl Finding {
    pub fn warning(message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Warning,
            message: message.into(),
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self {
            severity: Severity::Error,
            message: message.into(),
        }
    }
}

/// Everything the state checks read, supplied explicitly.
///
/// Passing the environment in rather than reaching for `dirs::home_dir()` is
/// what makes these checks testable against a deliberately unhealthy fixture.
#[derive(Debug, Clone)]
pub struct HealthEnv {
    /// The resolved data directory (usually `~/.locus/data`).
    pub data_dir: PathBuf,
    /// Roots that may hold delegation artifacts. Both the current and legacy
    /// locations, so a half-migrated install is still measured correctly.
    pub delegation_roots: Vec<PathBuf>,
    /// `~/.claude/settings.json`, if Claude Code is installed.
    pub claude_settings: Option<PathBuf>,
    /// The canonical OpenCode credential file.
    pub opencode_auth: Option<PathBuf>,
    /// Version of the `locus` binary actually on PATH — the one hooks invoke.
    pub locus_on_path_version: Option<String>,
    /// Version of the running build.
    pub running_version: String,
    /// Wall clock, injected so tests are not time-dependent.
    pub now: SystemTime,
}

/// Warn above this many retained delegation directories.
pub const MAX_DELEGATIONS: usize = 50;
/// Warn above this much retained delegation data.
pub const MAX_DELEGATION_BYTES: u64 = 250 * 1024 * 1024;
/// Warn above this size for the data directory's git repository.
pub const MAX_DATA_GIT_BYTES: u64 = 500 * 1024 * 1024;
/// Warn when the last sync is older than this.
pub const MAX_SYNC_AGE_DAYS: u64 = 14;

/// Run every state check and return what is wrong.
pub fn check_all(env: &HealthEnv) -> Vec<Finding> {
    let mut findings = Vec::new();
    findings.extend(check_duplicate_hooks(env));
    findings.extend(check_delegation_footprint(env));
    findings.extend(check_stray_credentials(env));
    findings.extend(check_credential_expiry(env));
    findings.extend(check_data_git_size(env));
    findings.extend(check_sync_age(env));
    findings.extend(check_version_drift(env));
    findings
}

/// DEV-504: an install registered by an older Locus carries two commands for
/// every event, and every one of them runs on every matching tool call.
pub fn check_duplicate_hooks(env: &HealthEnv) -> Vec<Finding> {
    let Some(path) = env.claude_settings.as_ref() else {
        return Vec::new();
    };
    let Ok(body) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(settings) = serde_json::from_str::<serde_json::Value>(&body) else {
        return vec![Finding::error(format!(
            "{} is not valid JSON — Claude Code will ignore it entirely",
            path.display()
        ))];
    };
    let Some(hooks) = settings.get("hooks").and_then(|h| h.as_object()) else {
        return Vec::new();
    };

    let mut findings = Vec::new();
    for (event, groups) in hooks {
        let commands: Vec<&str> = groups
            .as_array()
            .map(|groups| {
                groups
                    .iter()
                    .filter_map(|g| g.get("hooks").and_then(|h| h.as_array()))
                    .flatten()
                    .filter_map(|h| h.get("command").and_then(|c| c.as_str()))
                    .filter(|c| is_locus_hook_command(c))
                    .collect()
            })
            .unwrap_or_default();

        if commands.len() > 1 {
            findings.push(Finding::warning(format!(
                "Claude Code hook `{}` runs {} Locus commands, not 1 ({}). \
                 Every one fires on every matching event. \
                 Run `locus platform add claude-code` to repair.",
                event,
                commands.len(),
                commands.join(", ")
            )));
        }
    }
    findings.sort_by(|a, b| a.message.cmp(&b.message));
    findings
}

/// DEV-505: delegation artifacts accumulate one directory per run and nothing
/// used to remove them.
pub fn check_delegation_footprint(env: &HealthEnv) -> Vec<Finding> {
    let mut count = 0usize;
    let mut bytes = 0u64;
    for root in &env.delegation_roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            if !entry.metadata().map(|m| m.is_dir()).unwrap_or(false) {
                continue;
            }
            count += 1;
            bytes += dir_size(&entry.path());
        }
    }

    let mut findings = Vec::new();
    if count > MAX_DELEGATIONS {
        findings.push(Finding::warning(format!(
            "{} delegation directories retained (threshold {}). \
             Run `locus delegate prune --sandboxes --apply`.",
            count, MAX_DELEGATIONS
        )));
    }
    if bytes > MAX_DELEGATION_BYTES {
        findings.push(Finding::warning(format!(
            "Delegation artifacts hold {} (threshold {}). \
             Run `locus delegate prune --sandboxes --apply`.",
            format_bytes(bytes),
            format_bytes(MAX_DELEGATION_BYTES)
        )));
    }
    findings
}

/// DEV-505: a credential copy outside the one place credentials belong.
pub fn check_stray_credentials(env: &HealthEnv) -> Vec<Finding> {
    let expected = env.opencode_auth.clone();
    let mut stray = Vec::new();
    for root in &env.delegation_roots {
        collect_auth_files(root, expected.as_deref(), &mut stray, 0);
    }

    if stray.is_empty() {
        return Vec::new();
    }
    vec![Finding::warning(format!(
        "{} OpenCode credential file(s) outside the expected location \
         (e.g. {}). Run `locus delegate prune --sandboxes --apply`.",
        stray.len(),
        stray[0].display()
    ))]
}

/// The credential the whole delegation path depends on has expired, or is
/// about to. Nothing else in the stack reports this until a run fails with a
/// `401` that reads like a user problem.
pub fn check_credential_expiry(env: &HealthEnv) -> Vec<Finding> {
    let Some(path) = env.opencode_auth.as_ref() else {
        return Vec::new();
    };
    let Some(expiry) = latest_expiry_secs(path) else {
        return Vec::new();
    };
    let now = env
        .now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    if expiry < now {
        return vec![Finding::error(format!(
            "OpenCode credential at {} expired {} ago — delegation will fail \
             with `Token refresh failed: 401`. Run `opencode auth login`.",
            path.display(),
            format_duration((now - expiry) as u64)
        ))];
    }
    Vec::new()
}

/// The data directory's git repository grows without bound if large artifacts
/// were ever committed to it.
pub fn check_data_git_size(env: &HealthEnv) -> Vec<Finding> {
    let git_dir = env.data_dir.join(".git");
    if !git_dir.exists() {
        return Vec::new();
    }
    let bytes = dir_size(&git_dir);
    if bytes > MAX_DATA_GIT_BYTES {
        return vec![Finding::warning(format!(
            "data/.git is {} (threshold {}). History is carrying artifacts \
             that probably should not be committed.",
            format_bytes(bytes),
            format_bytes(MAX_DATA_GIT_BYTES)
        ))];
    }
    Vec::new()
}

/// Memory that is not synced is memory that exists on exactly one machine.
pub fn check_sync_age(env: &HealthEnv) -> Vec<Finding> {
    let git_dir = env.data_dir.join(".git");
    if !git_dir.exists() {
        return Vec::new();
    }
    let Some(last) = last_commit_epoch(&env.data_dir) else {
        return Vec::new();
    };
    let now = env
        .now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let age = now.saturating_sub(last);
    if age > (MAX_SYNC_AGE_DAYS * 86_400) as i64 {
        return vec![Finding::warning(format!(
            "Last data sync was {} ago (threshold {} days). Run `locus sync`.",
            format_duration(age as u64),
            MAX_SYNC_AGE_DAYS
        ))];
    }
    Vec::new()
}

/// DEV-521: the `locus` on PATH is the binary that hooks actually invoke. If it
/// is not this build, then every check that reasons about bundled content is
/// reasoning about content a different binary manages — which is exactly how
/// two live defects went unreported on this machine.
pub fn check_version_drift(env: &HealthEnv) -> Vec<Finding> {
    let Some(on_path) = env.locus_on_path_version.as_ref() else {
        return Vec::new();
    };
    if on_path != &env.running_version {
        return vec![Finding::warning(format!(
            "`locus` on PATH is {} but this build is {}. Hooks and generated \
             config come from the PATH binary, so checks here may not describe \
             what is actually running. Run `locus upgrade`.",
            on_path, env.running_version
        ))];
    }
    Vec::new()
}

// --- helpers ---------------------------------------------------------------

fn collect_auth_files(dir: &Path, expected: Option<&Path>, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 4 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            // A link to the canonical credential is the fix, not the problem.
            continue;
        }
        if metadata.is_dir() {
            collect_auth_files(&path, expected, out, depth + 1);
        } else if path.file_name() == Some(std::ffi::OsStr::new("auth.json"))
            && Some(path.as_path()) != expected
        {
            out.push(path);
        }
    }
}

/// The furthest-future `expires` across providers, normalised to seconds.
fn latest_expiry_secs(path: &Path) -> Option<i64> {
    let body = std::fs::read_to_string(path).ok()?;
    let parsed: serde_json::Value = serde_json::from_str(&body).ok()?;
    let raw = parsed
        .as_object()?
        .values()
        .filter_map(|entry| entry.get("expires").and_then(|v| v.as_i64()))
        .max()?;
    // OpenCode records milliseconds; tolerate seconds so the check does not
    // depend on a format detail it has no control over.
    Some(if raw > 100_000_000_000 { raw / 1000 } else { raw })
}

fn last_commit_epoch(data_dir: &Path) -> Option<i64> {
    let output = std::process::Command::new("git")
        .args(["log", "-1", "--format=%ct"])
        .current_dir(data_dir)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout).trim().parse().ok()
}

fn dir_size(path: &Path) -> u64 {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return 0;
    };
    if metadata.file_type().is_symlink() {
        return 0;
    }
    if metadata.is_file() {
        return metadata.len();
    }
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    entries.flatten().map(|e| dir_size(&e.path())).sum()
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, UNITS[unit])
    } else {
        format!("{:.1} {}", value, UNITS[unit])
    }
}

fn format_duration(seconds: u64) -> String {
    let days = seconds / 86_400;
    if days >= 1 {
        format!("{} day(s)", days)
    } else {
        format!("{} hour(s)", seconds / 3_600)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("locus-health-{}-{}", label, nanos));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn env_at(root: &Path) -> HealthEnv {
        HealthEnv {
            data_dir: root.join("data"),
            delegation_roots: vec![root.join("data").join("delegations")],
            claude_settings: None,
            opencode_auth: None,
            locus_on_path_version: None,
            running_version: "0.2.1".into(),
            now: SystemTime::now(),
        }
    }

    /// A healthy install produces nothing. Without this, a check that returns a
    /// finding unconditionally would look like it works.
    #[test]
    fn a_healthy_install_produces_no_findings() {
        let root = temp_root("healthy");
        std::fs::create_dir_all(root.join("data").join("delegations")).unwrap();

        let settings = root.join("settings.json");
        std::fs::write(
            &settings,
            serde_json::to_string(&serde_json::json!({
                "hooks": {
                    "Stop": [{ "matcher": "", "hooks": [
                        { "type": "command", "command": "locus hook stop" }
                    ]}]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let mut env = env_at(&root);
        env.claude_settings = Some(settings);
        env.locus_on_path_version = Some("0.2.1".into());

        assert_eq!(check_all(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// The whole point of DEV-506: an unhealthy fixture must produce findings.
    /// This is the machine's real state, in a temp directory.
    #[test]
    fn an_unhealthy_install_produces_findings_across_every_check() {
        let root = temp_root("unhealthy");
        let delegations = root.join("data").join("delegations");

        // 60 delegation dirs, each with a stray credential copy.
        for i in 0..60 {
            let auth_dir = delegations
                .join(format!("delegate-{}", i))
                .join("opencode-data")
                .join("opencode");
            std::fs::create_dir_all(&auth_dir).unwrap();
            std::fs::write(auth_dir.join("auth.json"), br#"{"openai":{"expires":1}}"#).unwrap();
        }

        // Hooks registered twice — absolute path plus bare command.
        let settings = root.join("settings.json");
        std::fs::write(
            &settings,
            serde_json::to_string(&serde_json::json!({
                "hooks": {
                    "PostToolUse": [{ "matcher": "", "hooks": [
                        { "type": "command", "command": "/Users/x/.cargo/bin/locus hook post-tool-use" },
                        { "type": "command", "command": "locus hook post-tool-use" }
                    ]}],
                    "Stop": [{ "matcher": "", "hooks": [
                        { "type": "command", "command": "/Users/x/.cargo/bin/locus hook stop" },
                        { "type": "command", "command": "locus hook stop" }
                    ]}]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        // A canonical credential that expired long ago.
        let canonical = root.join("canonical-auth.json");
        std::fs::write(&canonical, br#"{"openai":{"type":"oauth","expires":1000}}"#).unwrap();

        let mut env = env_at(&root);
        env.claude_settings = Some(settings);
        env.opencode_auth = Some(canonical);
        env.locus_on_path_version = Some("0.1.0".into());

        let findings = check_all(&env);
        assert!(
            findings.len() >= 5,
            "unhealthy fixture must produce findings, got {:#?}",
            findings
        );

        let all = findings
            .iter()
            .map(|f| f.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all.contains("PostToolUse"), "duplicate hooks: {}", all);
        assert!(all.contains("Stop"), "duplicate hooks: {}", all);
        assert!(all.contains("delegation directories"), "count: {}", all);
        assert!(all.contains("credential file(s) outside"), "stray: {}", all);
        assert!(all.contains("expired"), "expiry: {}", all);
        assert!(all.contains("on PATH is 0.1.0"), "drift: {}", all);

        // And the severity split is real, not decorative.
        assert!(findings.iter().any(|f| f.severity == Severity::Error));
        assert!(findings.iter().any(|f| f.severity == Severity::Warning));

        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn single_registration_is_not_reported_as_duplicate() {
        let root = temp_root("single-hook");
        let settings = root.join("settings.json");
        std::fs::write(
            &settings,
            serde_json::to_string(&serde_json::json!({
                "hooks": {
                    "Stop": [{ "matcher": "", "hooks": [
                        { "type": "command", "command": "locus hook stop" },
                        { "type": "command", "command": "some-other-tool --stop" }
                    ]}]
                }
            }))
            .unwrap(),
        )
        .unwrap();

        let mut env = env_at(&root);
        env.claude_settings = Some(settings);
        assert_eq!(check_duplicate_hooks(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// A symlinked credential is DEV-505's fix, not a stray copy.
    #[cfg(unix)]
    #[test]
    fn a_linked_credential_is_not_a_stray_copy() {
        let root = temp_root("linked-cred");
        let canonical = root.join("canonical-auth.json");
        std::fs::write(&canonical, br#"{"openai":{"expires":99999999999999}}"#).unwrap();

        let sandbox = root
            .join("data")
            .join("delegations")
            .join("delegate-1")
            .join("opencode-data")
            .join("opencode");
        std::fs::create_dir_all(&sandbox).unwrap();
        std::os::unix::fs::symlink(&canonical, sandbox.join("auth.json")).unwrap();

        let mut env = env_at(&root);
        env.opencode_auth = Some(canonical);
        assert_eq!(check_stray_credentials(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_valid_credential_does_not_warn() {
        let root = temp_root("valid-cred");
        let canonical = root.join("auth.json");
        let future = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 86_400;
        std::fs::write(
            &canonical,
            format!(r#"{{"openai":{{"expires":{}}}}}"#, future * 1000),
        )
        .unwrap();

        let mut env = env_at(&root);
        env.opencode_auth = Some(canonical);
        assert_eq!(check_credential_expiry(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn expiry_is_read_in_seconds_or_milliseconds() {
        let root = temp_root("expiry-units");
        let path = root.join("auth.json");
        std::fs::write(&path, br#"{"a":{"expires":1788000000}}"#).unwrap();
        assert_eq!(latest_expiry_secs(&path), Some(1_788_000_000));
        std::fs::write(&path, br#"{"a":{"expires":1788000000000}}"#).unwrap();
        assert_eq!(latest_expiry_secs(&path), Some(1_788_000_000));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn malformed_settings_is_an_error_not_a_warning() {
        let root = temp_root("bad-settings");
        let settings = root.join("settings.json");
        std::fs::write(&settings, "{ not json").unwrap();

        let mut env = env_at(&root);
        env.claude_settings = Some(settings);
        let findings = check_duplicate_hooks(&env);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].severity, Severity::Error);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_missing_delegations_root_is_not_a_finding() {
        let root = temp_root("no-delegations");
        let env = env_at(&root);
        assert_eq!(check_delegation_footprint(&env), Vec::new());
        assert_eq!(check_stray_credentials(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }
}
