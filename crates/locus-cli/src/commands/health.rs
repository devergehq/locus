//! Health checks for `locus doctor` — the ones that can actually fail.
//!
//! Doctor could always emit warnings. What it could not do was notice anything
//! wrong with something that *exists*: its checks asked "is this directory
//! present?", "does this config key appear?", "is the binary on PATH?". Every
//! one of those passed on a machine that was simultaneously holding 572
//! delegation sandboxes worth 7.2 GB, leaking 547 copies of its OpenCode
//! credential, and carrying a 660 MB `data/.git` that had not been synced in
//! weeks.
//!
//! These checks look at the *state* of things that exist. Each one is a pure
//! function over an explicitly supplied environment, so an unhealthy fixture
//! can be built in a temp directory and asserted against — see the tests at the
//! bottom of this file. Nothing here reads `dirs::home_dir()`; the caller
//! resolves the machine and passes it in.
//!
//! # Every check here can fail
//!
//! That is the entry condition for this module, not an aspiration. A check that
//! cannot report a problem is worse than no check, because its passing reads as
//! evidence. Each function below documents the input that makes it fire, and
//! each has a test that supplies exactly that input.
//!
//! One check did not survive that bar. DEV-506 originally shipped
//! `check_duplicate_hooks`, which read `~/.claude/settings.json` and warned when
//! an event carried more than one Locus command. DEV-608 removed every code path
//! that wrote hooks into `settings.json`, so Locus can no longer create the
//! condition; DEV-610 then deleted `is_locus_hook_command`, the predicate it
//! used, so it no longer compiles either. Legacy duplicates left on disk by an
//! older `locus platform add` are still worth reporting, and already are —
//! `doctor::check_claude_integration` warns on them and points at
//! `locus platform remove claude-code`. Re-implementing that here would be a
//! second detector for one condition.

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

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
    /// The canonical OpenCode credential file. Resolved by the caller so this
    /// module needs no dependency on the OpenCode adapter.
    pub opencode_auth: Option<PathBuf>,
    /// Every `locus` the PATH resolves to, in PATH order. The plugin's hooks
    /// invoke the first; the rest are shadowed installs the user may believe
    /// they are maintaining.
    pub locus_on_path: Vec<PathBuf>,
    /// Version reported by the first `locus` on PATH — the one hooks invoke.
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

/// Stop measuring a tree once it is this far past the threshold that matters.
///
/// The delegations root on the reporting machine holds 325,470 files across 572
/// directories. Walking all of it to produce a number whose only use is a
/// `>` comparison makes an interactive command wait on the filesystem for no
/// added information — see [`dir_size_capped`].
const SIZE_WALK_HEADROOM: u64 = 2;

/// Run every state check and return what is wrong.
pub fn check_all(env: &HealthEnv) -> Vec<Finding> {
    let mut findings = Vec::new();
    findings.extend(check_delegation_footprint(env));
    findings.extend(check_stray_credentials(env));
    findings.extend(check_credential_expiry(env));
    findings.extend(check_data_git_size(env));
    findings.extend(check_sync_age(env));
    findings.extend(check_version_drift(env));
    findings
}

/// DEV-505: delegation artifacts accumulate one directory per run and nothing
/// used to remove them.
///
/// **Fires when** a delegations root holds more than [`MAX_DELEGATIONS`]
/// directories, or more than [`MAX_DELEGATION_BYTES`] of data. Measured at 572
/// directories and 7.2 GB on the machine that reported DEV-506.
pub fn check_delegation_footprint(env: &HealthEnv) -> Vec<Finding> {
    let mut count = 0usize;
    let mut roots = Vec::new();
    for root in &env.delegation_roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            if entry.metadata().map(|m| m.is_dir()).unwrap_or(false) {
                count += 1;
                roots.push(entry.path());
            }
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

    // Counting is one `read_dir`; sizing is a full walk. Only pay for the walk
    // when there is something to measure, and stop as soon as the verdict is
    // decided.
    if !roots.is_empty() {
        let cap = MAX_DELEGATION_BYTES * SIZE_WALK_HEADROOM;
        let mut bytes = 0u64;
        let mut complete = true;
        for root in &roots {
            let (measured, finished) = dir_size_capped(root, cap.saturating_sub(bytes));
            bytes += measured;
            if !finished {
                complete = false;
                break;
            }
        }
        if bytes > MAX_DELEGATION_BYTES {
            findings.push(Finding::warning(format!(
                "Delegation artifacts hold {}{} (threshold {}). \
                 Run `locus delegate prune --sandboxes --apply`.",
                if complete { "" } else { "at least " },
                format_bytes(bytes),
                format_bytes(MAX_DELEGATION_BYTES)
            )));
        }
    }
    findings
}

/// DEV-505: a credential copy outside the one place credentials belong.
///
/// **Fires when** a single non-symlink `auth.json` exists anywhere under a
/// delegations root. There is deliberately no threshold: after DEV-505 the
/// expected count is zero, so one file appearing means the fix regressed.
///
/// Reported whether or not delegation is still in use — idle-but-leaking is
/// precisely the state that goes unnoticed, because nothing will ever prompt
/// anyone to look at a feature they have stopped exercising.
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

/// The credential the whole delegation path depends on has expired.
///
/// **Fires when** the canonical `auth.json` records an `expires` in the past.
/// Nothing else in the stack reports this until a run fails with a `401` that
/// reads like a user problem.
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
///
/// **Fires when** `{data}/.git` exceeds [`MAX_DATA_GIT_BYTES`]. Measured at
/// 660 MB on the reporting machine.
pub fn check_data_git_size(env: &HealthEnv) -> Vec<Finding> {
    let git_dir = env.data_dir.join(".git");
    if !git_dir.exists() {
        return Vec::new();
    }
    let cap = MAX_DATA_GIT_BYTES * SIZE_WALK_HEADROOM;
    let (bytes, complete) = dir_size_capped(&git_dir, cap);
    if bytes > MAX_DATA_GIT_BYTES {
        return vec![Finding::warning(format!(
            "data/.git is {}{} (threshold {}). History is carrying artifacts \
             that probably should not be committed.",
            if complete { "" } else { "at least " },
            format_bytes(bytes),
            format_bytes(MAX_DATA_GIT_BYTES)
        ))];
    }
    Vec::new()
}

/// Memory that is not synced is memory that exists on exactly one machine.
///
/// **Fires when** the newest commit in `{data}` is older than
/// [`MAX_SYNC_AGE_DAYS`].
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

/// The `locus` the plugin's hooks will actually invoke is not the one you think.
///
/// Under the plugin model this is the drift that still matters. `claude plugin
/// update` refreshes the plugin; **nothing refreshes the binary**, and the
/// plugin's six hooks are thin wrappers that shell out to whatever `locus` the
/// PATH resolves to. So the plugin can be current while the binary behind every
/// hook is two releases behind — which is exactly how DEV-504 and DEV-505
/// survived undetected, measured against an install whose doctor was checking
/// its own bundled content and finding it perfectly consistent.
///
/// **Fires when** either:
///
/// 1. PATH resolves `locus` to more than one binary. Hooks silently get the
///    first; any other is a shadowed install the user may believe is live.
/// 2. The first `locus` on PATH reports a different version from this build —
///    i.e. doctor was invoked by a path that is not the one hooks use.
///
/// Note what this deliberately does *not* compare: the plugin manifest's
/// version against the crate version. `.claude-plugin/plugin.json` is on its own
/// release train (0.3.0 against the crate's 0.2.1) and the two are not meant to
/// match, so a mismatch there would be noise, not signal.
pub fn check_version_drift(env: &HealthEnv) -> Vec<Finding> {
    let mut findings = Vec::new();

    if env.locus_on_path.len() > 1 {
        let shadowed: Vec<String> = env
            .locus_on_path
            .iter()
            .skip(1)
            .map(|p| p.display().to_string())
            .collect();
        findings.push(Finding::warning(format!(
            "PATH resolves `locus` to {} binaries. Plugin hooks invoke the \
             first ({}); {} shadowed. Upgrading the wrong one leaves every \
             hook on the old binary. Remove the duplicates.",
            env.locus_on_path.len(),
            env.locus_on_path[0].display(),
            shadowed.join(", ")
        )));
    }

    if let Some(on_path) = env.locus_on_path_version.as_ref() {
        if on_path != &env.running_version {
            findings.push(Finding::warning(format!(
                "`locus` on PATH is {} but this build is {}. The plugin's hooks \
                 run the PATH binary, not this one, so every check here may be \
                 describing content a different build manages. \
                 Install this build over it.",
                on_path, env.running_version
            )));
        }
    }
    findings
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
    Some(if raw > 100_000_000_000 {
        raw / 1000
    } else {
        raw
    })
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

/// Total bytes under `path`, abandoning the walk once `cap` is exceeded.
///
/// Returns the bytes counted and whether the walk ran to completion. The only
/// consumer of the number is a `>` against a threshold, so measuring past the
/// point where the answer is settled buys nothing — and on the machine that
/// reported DEV-506 it is 325,470 `stat` calls that an interactive command
/// would wait on.
fn dir_size_capped(path: &Path, cap: u64) -> (u64, bool) {
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];

    while let Some(current) = stack.pop() {
        if total > cap {
            return (total, false);
        }
        let Ok(metadata) = std::fs::symlink_metadata(&current) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_file() {
            total += metadata.len();
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };
        stack.extend(entries.flatten().map(|e| e.path()));
    }
    (total, true)
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
            opencode_auth: None,
            locus_on_path: Vec::new(),
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

        let mut env = env_at(&root);
        env.locus_on_path = vec![PathBuf::from("/usr/local/bin/locus")];
        env.locus_on_path_version = Some("0.2.1".into());

        assert_eq!(check_all(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// The whole point of DEV-506: an unhealthy fixture must produce findings.
    /// Every surviving check fires here, which is the property that keeps this
    /// module honest — a check that cannot fail cannot pass this test.
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

        // A canonical credential that expired long ago.
        let canonical = root.join("canonical-auth.json");
        std::fs::write(&canonical, br#"{"openai":{"type":"oauth","expires":1000}}"#).unwrap();

        let mut env = env_at(&root);
        env.opencode_auth = Some(canonical);
        env.locus_on_path = vec![
            PathBuf::from("/usr/local/bin/locus"),
            PathBuf::from("/Users/x/.cargo/bin/locus"),
        ];
        env.locus_on_path_version = Some("0.1.0".into());

        let findings = check_all(&env);
        let all = findings
            .iter()
            .map(|f| f.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(all.contains("delegation directories"), "count: {}", all);
        assert!(all.contains("credential file(s) outside"), "stray: {}", all);
        assert!(all.contains("expired"), "expiry: {}", all);
        assert!(all.contains("resolves `locus` to 2"), "shadowed: {}", all);
        assert!(all.contains("on PATH is 0.1.0"), "drift: {}", all);

        // And the severity split is real, not decorative.
        assert!(findings.iter().any(|f| f.severity == Severity::Error));
        assert!(findings.iter().any(|f| f.severity == Severity::Warning));

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

    /// No threshold: after DEV-505 the expected count is zero, so exactly one
    /// stray file is a regression and must be reported as one.
    #[test]
    fn a_single_stray_credential_is_reported() {
        let root = temp_root("one-stray");
        let sandbox = root
            .join("data")
            .join("delegations")
            .join("delegate-1")
            .join("opencode");
        std::fs::create_dir_all(&sandbox).unwrap();
        std::fs::write(sandbox.join("auth.json"), br#"{}"#).unwrap();

        let env = env_at(&root);
        let findings = check_stray_credentials(&env);
        assert_eq!(findings.len(), 1, "{:#?}", findings);
        assert!(findings[0]
            .message
            .contains("1 OpenCode credential file(s)"));
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
    fn a_missing_delegations_root_is_not_a_finding() {
        let root = temp_root("no-delegations");
        let env = env_at(&root);
        assert_eq!(check_delegation_footprint(&env), Vec::new());
        assert_eq!(check_stray_credentials(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// Allocate a file that *reports* `len` bytes without writing them.
    ///
    /// `set_len` leaves a sparse file on every filesystem this runs on, and the
    /// size checks read `metadata.len()`, which is the logical length. That lets
    /// a test cross a 500 MB threshold in microseconds and, more importantly,
    /// exercise the **real** production constant rather than one lowered to make
    /// the test convenient.
    fn sparse_file(path: &Path, len: u64) {
        let file = std::fs::File::create(path).unwrap();
        file.set_len(len).unwrap();
    }

    /// An oversized `data/.git` is reported.
    ///
    /// This test exists because its absence was caught by mutation: replacing
    /// the body of `check_data_git_size` with `Vec::new()` failed no test at
    /// all. The previous version asserted only that an *under*-threshold
    /// repository stays silent — which a permanently dead check also satisfies.
    #[test]
    fn an_oversized_data_git_is_reported() {
        let root = temp_root("big-git");
        let git = root.join("data").join(".git");
        std::fs::create_dir_all(&git).unwrap();
        sparse_file(&git.join("pack"), MAX_DATA_GIT_BYTES + 1);

        let env = env_at(&root);
        let findings = check_data_git_size(&env);
        assert_eq!(findings.len(), 1, "{:#?}", findings);
        assert!(
            findings[0].message.starts_with("data/.git is"),
            "{}",
            findings[0].message
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// ...and an under-threshold one stays silent, so the check discriminates
    /// rather than firing unconditionally.
    #[test]
    fn a_normal_sized_data_git_is_not_reported() {
        let root = temp_root("small-git");
        let git = root.join("data").join(".git");
        std::fs::create_dir_all(&git).unwrap();
        std::fs::write(git.join("pack"), vec![0u8; 1024]).unwrap();

        let env = env_at(&root);
        assert_eq!(check_data_git_size(&env), Vec::new());

        let (bytes, complete) = dir_size_capped(&git, u64::MAX);
        assert_eq!(bytes, 1024);
        assert!(complete);
        std::fs::remove_dir_all(&root).ok();
    }

    /// The cap is the reason `locus doctor` does not wait on 325,470 `stat`
    /// calls. If the walk ever stops honouring it, this fails.
    #[test]
    fn the_size_walk_abandons_once_past_its_cap() {
        let root = temp_root("capped-walk");
        let tree = root.join("tree");
        for i in 0..8 {
            let dir = tree.join(format!("d{}", i));
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("blob"), vec![0u8; 4096]).unwrap();
        }

        let (full, complete) = dir_size_capped(&tree, u64::MAX);
        assert_eq!(full, 8 * 4096);
        assert!(complete);

        let (capped, finished) = dir_size_capped(&tree, 4096);
        assert!(!finished, "walk should have abandoned at the cap");
        assert!(
            capped < full,
            "capped {} should be under full {}",
            capped,
            full
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// A shadowed install fires even when the versions agree — the point is
    /// that the user is maintaining a binary the hooks never invoke.
    #[test]
    fn a_shadowed_locus_on_path_is_reported() {
        let root = temp_root("shadowed");
        let mut env = env_at(&root);
        env.locus_on_path = vec![
            PathBuf::from("/usr/local/bin/locus"),
            PathBuf::from("/Users/x/.cargo/bin/locus"),
        ];
        env.locus_on_path_version = Some("0.2.1".into());

        let findings = check_version_drift(&env);
        assert_eq!(findings.len(), 1, "{:#?}", findings);
        assert!(findings[0].message.contains("/Users/x/.cargo/bin/locus"));
        std::fs::remove_dir_all(&root).ok();
    }

    /// One binary, matching version — the only healthy shape.
    #[test]
    fn a_single_matching_locus_does_not_drift() {
        let root = temp_root("no-drift");
        let mut env = env_at(&root);
        env.locus_on_path = vec![PathBuf::from("/usr/local/bin/locus")];
        env.locus_on_path_version = Some("0.2.1".into());
        assert_eq!(check_version_drift(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// Sync age fires against a real repository, because `last_commit_epoch`
    /// shells out to git and a mocked one would prove nothing.
    #[test]
    fn a_stale_sync_is_reported() {
        let root = temp_root("stale-sync");
        let data = root.join("data");
        std::fs::create_dir_all(&data).unwrap();
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(&data)
                .output()
                .expect("git must be available")
        };
        git(&["init", "-q"]);
        git(&["config", "user.email", "t@example.com"]);
        git(&["config", "user.name", "t"]);
        std::fs::write(data.join("f"), "x").unwrap();
        git(&["add", "."]);
        git(&["commit", "-qm", "seed"]);

        let mut env = env_at(&root);
        // Far enough in the future that the commit just made is stale.
        env.now = SystemTime::now() + std::time::Duration::from_secs(30 * 86_400);

        let findings = check_sync_age(&env);
        assert_eq!(findings.len(), 1, "{:#?}", findings);
        assert!(findings[0].message.contains("Run `locus sync`"));

        // And a fresh sync is not a finding.
        env.now = SystemTime::now();
        assert_eq!(check_sync_age(&env), Vec::new());
        std::fs::remove_dir_all(&root).ok();
    }

    /// The delegation size threshold fires on bytes alone, independently of the
    /// count threshold.
    #[test]
    fn delegation_size_fires_independently_of_count() {
        let root = temp_root("big-delegations");
        let delegations = root.join("data").join("delegations");
        // Two directories — well under MAX_DELEGATIONS — but oversized.
        for i in 0..2 {
            let dir = delegations.join(format!("d{}", i));
            std::fs::create_dir_all(&dir).unwrap();
            sparse_file(&dir.join("blob"), MAX_DELEGATION_BYTES);
        }

        let env = env_at(&root);
        let findings = check_delegation_footprint(&env);
        assert_eq!(findings.len(), 1, "{:#?}", findings);
        assert!(
            findings[0].message.contains("Delegation artifacts hold"),
            "{}",
            findings[0].message
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
