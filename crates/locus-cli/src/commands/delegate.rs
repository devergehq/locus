//! `locus delegate ...` — external execution delegation.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use std::collections::BTreeMap;

use chrono::{Local, TimeZone};
use clap::ValueEnum;
use locus_adapter_opencode::run::{
    discard_sandbox, parse::extract_token_usage, run_delegation, SANDBOX_DIRS,
};
use locus_core::{
    DelegationBackend, DelegationConfig, DelegationDefaults, DelegationManifest, DelegationMode,
    DelegationRequest, DelegationTaskKind, ExecutionMode, LocusConfig, LocusError, TokenUsage,
};
use serde::Serialize;

use crate::output;

/// Supported delegation backends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DelegateBackendArg {
    /// Run the delegated task through OpenCode.
    Opencode,
}

impl From<DelegateBackendArg> for DelegationBackend {
    fn from(value: DelegateBackendArg) -> Self {
        match value {
            DelegateBackendArg::Opencode => Self::OpenCode,
        }
    }
}

/// Broad category of delegated work.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DelegateTaskKindArg {
    /// Research using web/docs/code sources.
    Research,
    /// Read-only codebase exploration.
    CodeExploration,
    /// General bounded task.
    General,
}

impl From<DelegateTaskKindArg> for DelegationTaskKind {
    fn from(value: DelegateTaskKindArg) -> Self {
        match value {
            DelegateTaskKindArg::Research => Self::Research,
            DelegateTaskKindArg::CodeExploration => Self::CodeExploration,
            DelegateTaskKindArg::General => Self::General,
        }
    }
}

/// Delegate command output mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DelegateOutput {
    /// Emit compact JSON for machine consumption.
    Json,
    /// Emit human-readable status output.
    Human,
}

/// Execution-mode CLI flag (orchestration context).
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum ExecutionModeArg {
    /// Bare session — no Locus Algorithm loaded into the spawned process.
    Native,
    /// Full Locus Algorithm loaded into the spawned process. Rare; almost
    /// always you want `native` because the orchestrator is the *outer*
    /// session, not the delegated one.
    Algorithmic,
}

impl From<ExecutionModeArg> for ExecutionMode {
    fn from(value: ExecutionModeArg) -> Self {
        match value {
            ExecutionModeArg::Native => Self::Native,
            ExecutionModeArg::Algorithmic => Self::Algorithmic,
        }
    }
}

/// Arguments for `locus delegate run`.
#[derive(Debug, Clone)]
pub struct RunArgs {
    pub backend: DelegateBackendArg,
    pub task_kind: DelegateTaskKindArg,
    pub model: Option<String>,
    pub dir: PathBuf,
    pub prompt: String,
    pub agent: Option<String>,
    pub variant: Option<String>,
    pub context_files: Vec<PathBuf>,
    pub artifact_dir: Option<PathBuf>,
    pub timeout_seconds: u64,
    pub dry_run: bool,
    pub output: DelegateOutput,
    pub mode: ExecutionModeArg,
}

/// Run a delegated task through the selected backend.
pub fn run(args: RunArgs) -> Result<(), LocusError> {
    let dry_run = args.dry_run;
    let output_mode = args.output;
    let delegation = load_delegation_config();
    let request = build_request(args, &delegation)?;
    validate_request(&request)?;

    if dry_run {
        return print_json(&request);
    }

    let result = match request.backend {
        DelegationBackend::OpenCode => run_delegation(&request)?,
    };

    // Bound retention opportunistically. A successful run has already dropped
    // its own sandbox; this is what stops failed runs and raw JSONL from
    // accumulating forever. Best-effort — a housekeeping failure must never
    // turn a successful delegation into an error.
    if let Some(root) = request.artifact_dir.parent() {
        let _ = sweep_expired(root, SystemTime::now());
    }

    match output_mode {
        DelegateOutput::Json => print_json(&result),
        DelegateOutput::Human => print_human_result(&result),
    }
}

/// Load delegation routing config from `~/.locus/locus.yaml`.
///
/// Falls back to an empty config when the file is missing or unparseable —
/// resolution will produce a clear error at lookup time if no model can be
/// resolved.
fn load_delegation_config() -> DelegationConfig {
    let Some(home) = dirs::home_dir() else {
        return DelegationConfig::default();
    };
    let path = home.join(".locus").join("locus.yaml");
    LocusConfig::from_file(&path)
        .map(|cfg| cfg.delegation)
        .unwrap_or_default()
}

fn build_request(
    args: RunArgs,
    delegation: &DelegationConfig,
) -> Result<DelegationRequest, LocusError> {
    let id = new_request_id();
    let artifact_dir = args
        .artifact_dir
        .unwrap_or_else(|| default_artifact_dir(&id));

    let backend: DelegationBackend = args.backend.into();
    let task_kind: DelegationTaskKind = args.task_kind.into();
    let defaults = delegation.lookup(backend.as_str(), task_kind.as_str());

    let model = resolve_model(args.model.as_deref(), defaults, &backend, &task_kind)?;
    let agent = resolve_optional(args.agent, defaults.and_then(|d| d.agent.clone()));
    let variant = resolve_optional(args.variant, defaults.and_then(|d| d.variant.clone()));

    Ok(DelegationRequest {
        id,
        backend,
        task_kind,
        model,
        agent,
        variant,
        workspace_dir: args.dir,
        prompt: args.prompt,
        context_files: args.context_files,
        mode: DelegationMode::ReadOnly,
        execution_mode: args.mode.into(),
        output_schema_version: DelegationRequest::CURRENT_SCHEMA_VERSION,
        artifact_dir,
        timeout_seconds: args.timeout_seconds,
    })
}

const FALLBACK_MODEL: &str = "openai/gpt-5.6-sol";

fn resolve_model(
    cli_model: Option<&str>,
    defaults: Option<&DelegationDefaults>,
    _backend: &DelegationBackend,
    _task_kind: &DelegationTaskKind,
) -> Result<String, LocusError> {
    if let Some(m) = cli_model.filter(|s| !s.trim().is_empty()) {
        return Ok(m.to_string());
    }
    if let Some(d) = defaults {
        if !d.model.trim().is_empty() {
            return Ok(d.model.clone());
        }
    }
    Ok(FALLBACK_MODEL.to_string())
}

fn resolve_optional(cli_value: Option<String>, default_value: Option<String>) -> Option<String> {
    cli_value
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or(default_value)
}

fn validate_request(request: &DelegationRequest) -> Result<(), LocusError> {
    if request.mode != DelegationMode::ReadOnly {
        return Err(LocusError::Config {
            message: "Only read_only delegation is currently supported".into(),
            path: None,
        });
    }

    if request.output_schema_version != DelegationRequest::CURRENT_SCHEMA_VERSION {
        return Err(LocusError::Config {
            message: format!(
                "Unsupported delegation schema version {}",
                request.output_schema_version
            ),
            path: None,
        });
    }

    if request.model.trim().is_empty() || request.model.contains(char::is_whitespace) {
        return Err(LocusError::Config {
            message: "Delegation model must be non-empty and contain no whitespace".into(),
            path: None,
        });
    }

    if request.prompt.trim().is_empty() {
        return Err(LocusError::Config {
            message: "Delegation prompt cannot be empty".into(),
            path: None,
        });
    }

    if request.timeout_seconds == 0 || request.timeout_seconds > 86_400 {
        return Err(LocusError::Config {
            message: "Delegation timeout must be between 1 and 86400 seconds".into(),
            path: None,
        });
    }

    if request.context_files.len() > 32 {
        return Err(LocusError::Config {
            message: "Delegation supports at most 32 context files".into(),
            path: None,
        });
    }

    if request.artifact_dir == request.workspace_dir {
        return Err(LocusError::Config {
            message: "Delegation artifact directory cannot equal workspace directory".into(),
            path: None,
        });
    }

    Ok(())
}

fn print_json<T: serde::Serialize>(value: &T) -> Result<(), LocusError> {
    let json = serde_json::to_string_pretty(value).map_err(|e| LocusError::Config {
        message: format!("Failed to serialize delegation output: {}", e),
        path: None,
    })?;

    let mut stdout = std::io::stdout().lock();
    stdout.write_all(json.as_bytes()).ok();
    stdout.write_all(b"\n").ok();
    Ok(())
}

fn print_human_result(result: &locus_core::DelegationResult) -> Result<(), LocusError> {
    output::print_header();
    output::section("Delegation Result");
    output::field("Status", &format!("{:?}", result.status));
    output::field("Backend", result.backend.as_str());
    output::field("Model", &result.model);
    output::field("Summary", &result.summary);
    if let Some(usage) = &result.usage {
        output::field(
            "Tokens",
            &format!(
                "{} total ({} input, {} output, {} reasoning, {} cache read)",
                format_number(usage.total_tokens),
                format_number(usage.input_tokens),
                format_number(usage.output_tokens),
                format_number(usage.reasoning_tokens),
                format_number(usage.cache_read_tokens),
            ),
        );
    }
    if let Some(path) = &result.raw_output_path {
        output::field("Raw output", &path.display().to_string());
    }
    if let Some(error) = &result.error {
        output::field("Error", error);
    }
    Ok(())
}

fn new_request_id() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    format!("delegate-{}", millis)
}

fn default_artifact_dir(id: &str) -> PathBuf {
    default_delegations_root().join(id)
}

/// Where new delegation artifacts are written.
///
/// Delegation scratch used to live under `data/memory/work/delegations`, which
/// put ephemeral sandboxes inside the memory tree that Locus syncs and treats as
/// durable. It is not memory — it is scratch with a manifest — so it now sits at
/// `data/delegations`.
fn default_delegations_root() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".locus").join("data").join("delegations")
}

/// The pre-DEV-505 location. Still enumerated by `ls`, `prune`, and `usage` so
/// existing delegations remain visible, prunable, and countable towards usage.
fn legacy_delegations_root() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".locus")
        .join("data")
        .join("memory")
        .join("work")
        .join("delegations")
}

/// The roots a maintenance command should walk.
///
/// An explicit `--root` is taken literally. Otherwise both the current and the
/// legacy root are walked, skipping whichever does not exist.
fn roots_to_scan(explicit: Option<PathBuf>) -> Vec<PathBuf> {
    match explicit {
        Some(root) => vec![root],
        None => [default_delegations_root(), legacy_delegations_root()]
            .into_iter()
            .filter(|r| r.exists())
            .collect(),
    }
}

/// Days after which a delegation's bulky artifacts are swept, leaving only the
/// manifest. Failed runs keep their sandbox for this long so they stay
/// diagnosable; successful runs have already discarded theirs at completion.
const RETENTION_DAYS: u64 = 7;

/// Arguments for `locus delegate ls`.
#[derive(Debug, Clone)]
pub struct LsArgs {
    pub root: Option<PathBuf>,
    pub output: DelegateOutput,
}

/// Arguments for `locus delegate prune`.
#[derive(Debug, Clone)]
pub struct PruneArgs {
    pub older_than: Option<String>,
    pub all: bool,
    /// Strip the OpenCode sandbox (and its credential copy) from every
    /// delegation, of any age, keeping the manifest and stdout artifacts.
    pub sandboxes: bool,
    pub apply: bool,
    pub keep_stdout: bool,
    pub root: Option<PathBuf>,
    pub output: DelegateOutput,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
struct DelegationEntry {
    id: String,
    path: PathBuf,
    age_seconds: u64,
    size_bytes: u64,
    opencode_data_bytes: u64,
    /// Bytes held by all three sandbox directories, not just `opencode-data`.
    sandbox_bytes: u64,
    /// Whether this entry holds a real credential copy (a symlink to the
    /// canonical file does not count).
    has_auth_copy: bool,
    /// The durable manifest, when one has been written.
    #[serde(skip_serializing_if = "Option::is_none")]
    manifest: Option<DelegationManifest>,
}

#[derive(Debug, Clone, Serialize)]
struct LsReport {
    roots: Vec<PathBuf>,
    entries: Vec<DelegationEntry>,
    total_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
struct PruneReport {
    roots: Vec<PathBuf>,
    applied: bool,
    keep_stdout: bool,
    /// Whether this was a sandbox-only sweep rather than a full delete.
    sandboxes_only: bool,
    selected: Vec<DelegationEntry>,
    freed_bytes: u64,
    /// Credential copies removed by the sweep. Counted separately because they
    /// are the reason prune is not merely a disk-space concern.
    auth_files_removed: usize,
}

/// List existing delegation artifact directories.
pub fn ls(args: LsArgs) -> Result<(), LocusError> {
    let roots = roots_to_scan(args.root);
    let now = SystemTime::now();
    let mut entries = Vec::new();
    for root in &roots {
        entries.extend(enumerate_delegations(root, now)?);
    }
    entries.sort_by(|a, b| b.age_seconds.cmp(&a.age_seconds));
    let total_bytes = entries.iter().map(|e| e.size_bytes).sum();

    let report = LsReport {
        roots,
        entries,
        total_bytes,
    };

    match args.output {
        DelegateOutput::Json => print_json(&report),
        DelegateOutput::Human => print_human_ls(&report),
    }
}

/// Prune delegation artifact directories.
///
/// Three selectors, exactly one of which must be given:
///
/// - `--older-than <dur>` — entries past an age
/// - `--all` — every entry
/// - `--sandboxes` — every entry of any age, but strip only the OpenCode
///   sandbox and leave the manifest and stdout artifacts in place. This is the
///   one-shot repair for installs that accumulated sandboxes before they were
///   discarded automatically.
///
/// Whichever selector is used, applying a prune also sweeps every stray
/// `auth.json` under every scanned root, regardless of the entry's age. A
/// credential copy is not a disk-space problem you wait out.
pub fn prune(args: PruneArgs) -> Result<(), LocusError> {
    let selectors = [args.all, args.older_than.is_some(), args.sandboxes]
        .iter()
        .filter(|selected| **selected)
        .count();
    if selectors != 1 {
        return Err(LocusError::Config {
            message: "Specify exactly one of --all, --older-than, or --sandboxes".into(),
            path: None,
        });
    }

    let cutoff = match &args.older_than {
        Some(spec) => Some(parse_duration(spec)?),
        None => None,
    };

    let roots = roots_to_scan(args.root);
    let now = SystemTime::now();
    let mut all_entries = Vec::new();
    for root in &roots {
        all_entries.extend(enumerate_delegations(root, now)?);
    }
    all_entries.sort_by(|a, b| b.age_seconds.cmp(&a.age_seconds));

    let selected: Vec<DelegationEntry> = all_entries
        .into_iter()
        .filter(|entry| match &cutoff {
            Some(min_age) => entry.age_seconds >= min_age.as_secs(),
            None => true,
        })
        .collect();

    let mut freed_bytes: u64 = 0;
    let mut auth_files_removed = 0usize;
    if args.apply {
        for entry in &selected {
            if args.sandboxes {
                freed_bytes += discard_sandbox(&entry.path)?;
            } else {
                freed_bytes += delete_entry(&entry.path, args.keep_stdout, &entry.id)?;
            }
        }
        // Belt and braces: catch credential copies in entries the selector
        // skipped, and any left behind by a --keep-stdout prune.
        for root in &roots {
            auth_files_removed += purge_auth_files(root)?;
        }
    } else {
        freed_bytes = if args.sandboxes {
            selected.iter().map(|e| e.sandbox_bytes).sum()
        } else {
            selected.iter().map(|e| e.size_bytes).sum()
        };
        auth_files_removed = selected.iter().filter(|e| e.has_auth_copy).count();
    }

    let report = PruneReport {
        roots,
        applied: args.apply,
        keep_stdout: args.keep_stdout,
        sandboxes_only: args.sandboxes,
        selected,
        freed_bytes,
        auth_files_removed,
    };

    match args.output {
        DelegateOutput::Json => print_json(&report),
        DelegateOutput::Human => print_human_prune(&report),
    }
}

/// Remove every `auth.json` under a delegations root, whatever its age.
///
/// Returns how many were removed. These are copies of the user's OpenCode
/// credentials made by pre-DEV-505 delegations; the current code links the
/// canonical file instead, so anything found here is residue.
fn purge_auth_files(root: &Path) -> Result<usize, LocusError> {
    if !root.exists() {
        return Ok(0);
    }
    let mut removed = 0usize;
    for entry in fs::read_dir(root).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read delegations root: {}", e),
        path: root.to_path_buf(),
    })? {
        let Ok(entry) = entry else { continue };
        if !entry.metadata().map(|m| m.is_dir()).unwrap_or(false) {
            continue;
        }
        let auth = auth_copy_path(&entry.path());
        // symlink_metadata: a link to the canonical credential is not a copy,
        // and deleting the canonical file behind it would be catastrophic.
        let Ok(metadata) = fs::symlink_metadata(&auth) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            let _ = fs::remove_file(&auth);
            continue;
        }
        fs::remove_file(&auth).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to remove stray credential copy: {}", e),
            path: auth.clone(),
        })?;
        removed += 1;
    }
    Ok(removed)
}

/// Where a delegation's stray credential copy would sit.
fn auth_copy_path(delegation_dir: &Path) -> PathBuf {
    delegation_dir
        .join("opencode-data")
        .join("opencode")
        .join("auth.json")
}

/// Discard bulky artifacts from delegations past the retention window, keeping
/// each manifest so `locus delegate usage` still reports on them.
///
/// Runs opportunistically after a delegation completes. Successful runs have
/// already dropped their sandbox at completion; this is what bounds the
/// retention of failed runs and of the raw stdout JSONL.
fn sweep_expired(root: &Path, now: SystemTime) -> Result<(), LocusError> {
    let retention = Duration::from_secs(RETENTION_DAYS * 86_400);
    for entry in enumerate_delegations(root, now)? {
        if entry.age_seconds < retention.as_secs() {
            continue;
        }
        if entry.manifest.is_none() {
            // No durable record yet — deleting the JSONL would delete the only
            // evidence this run ever happened. Leave it for an explicit prune.
            continue;
        }
        let _ = delete_entry_except_manifest(&entry.path);
    }
    Ok(())
}

/// Remove everything in a delegation directory except its manifest.
fn delete_entry_except_manifest(path: &Path) -> Result<u64, LocusError> {
    let mut freed = 0u64;
    for item in fs::read_dir(path).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read delegation dir: {}", e),
        path: path.to_path_buf(),
    })? {
        let Ok(item) = item else { continue };
        if item.file_name() == std::ffi::OsStr::new(DelegationManifest::FILE_NAME) {
            continue;
        }
        let item_path = item.path();
        let size = dir_size(&item_path)?;
        let removed = if item_path.is_dir() {
            fs::remove_dir_all(&item_path)
        } else {
            fs::remove_file(&item_path)
        };
        if removed.is_ok() {
            freed += size;
        }
    }
    Ok(freed)
}

/// Read a delegation's durable manifest, if it has one.
fn read_manifest(path: &Path) -> Option<DelegationManifest> {
    let body = fs::read(path.join(DelegationManifest::FILE_NAME)).ok()?;
    serde_json::from_slice(&body).ok()
}

fn enumerate_delegations(
    root: &Path,
    now: SystemTime,
) -> Result<Vec<DelegationEntry>, LocusError> {
    if !root.exists() {
        return Ok(Vec::new());
    }

    let read_dir = fs::read_dir(root).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read delegations root: {}", e),
        path: root.to_path_buf(),
    })?;

    let mut entries = Vec::new();
    for item in read_dir {
        let dir_entry = item.map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read delegations entry: {}", e),
            path: root.to_path_buf(),
        })?;

        let metadata = dir_entry.metadata().map_err(|e| LocusError::Filesystem {
            message: format!("Failed to stat delegation entry: {}", e),
            path: dir_entry.path(),
        })?;

        if !metadata.is_dir() {
            continue;
        }

        let path = dir_entry.path();
        let id = dir_entry.file_name().to_string_lossy().into_owned();
        let size_bytes = dir_size(&path)?;
        let opencode_data_bytes = dir_size(&path.join("opencode-data")).unwrap_or(0);
        let sandbox_bytes: u64 = SANDBOX_DIRS
            .iter()
            .map(|name| dir_size(&path.join(name)).unwrap_or(0))
            .sum();
        let has_auth_copy = fs::symlink_metadata(auth_copy_path(&path))
            .map(|m| !m.file_type().is_symlink())
            .unwrap_or(false);
        let manifest = read_manifest(&path);
        let mtime = metadata.modified().unwrap_or(UNIX_EPOCH);
        let age_seconds = now.duration_since(mtime).map(|d| d.as_secs()).unwrap_or(0);

        entries.push(DelegationEntry {
            id,
            path,
            age_seconds,
            size_bytes,
            opencode_data_bytes,
            sandbox_bytes,
            has_auth_copy,
            manifest,
        });
    }

    entries.sort_by(|a, b| b.age_seconds.cmp(&a.age_seconds));
    Ok(entries)
}

fn dir_size(path: &Path) -> Result<u64, LocusError> {
    if !path.exists() {
        return Ok(0);
    }

    let metadata = fs::metadata(path).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to stat path: {}", e),
        path: path.to_path_buf(),
    })?;

    if metadata.is_file() {
        return Ok(metadata.len());
    }

    if !metadata.is_dir() {
        return Ok(0);
    }

    let mut total = 0u64;
    let read_dir = fs::read_dir(path).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read directory: {}", e),
        path: path.to_path_buf(),
    })?;

    for item in read_dir {
        let entry = item.map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read entry: {}", e),
            path: path.to_path_buf(),
        })?;
        total += dir_size(&entry.path())?;
    }

    Ok(total)
}

fn delete_entry(path: &Path, keep_stdout: bool, id: &str) -> Result<u64, LocusError> {
    if !keep_stdout {
        let size = dir_size(path)?;
        fs::remove_dir_all(path).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to remove delegation dir: {}", e),
            path: path.to_path_buf(),
        })?;
        return Ok(size);
    }

    let stdout_name = format!("{}-opencode-stdout.jsonl", id);
    let stderr_name = format!("{}-opencode-stderr.log", id);

    let read_dir = fs::read_dir(path).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read delegation dir: {}", e),
        path: path.to_path_buf(),
    })?;

    let mut freed = 0u64;
    for item in read_dir {
        let entry = item.map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read entry: {}", e),
            path: path.to_path_buf(),
        })?;

        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str == stdout_name || name_str == stderr_name {
            continue;
        }

        let entry_path = entry.path();
        let size = dir_size(&entry_path)?;
        if entry_path.is_dir() {
            fs::remove_dir_all(&entry_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to remove directory: {}", e),
                path: entry_path.clone(),
            })?;
        } else {
            fs::remove_file(&entry_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to remove file: {}", e),
                path: entry_path.clone(),
            })?;
        }
        freed += size;
    }

    Ok(freed)
}

/// Arguments for `locus delegate usage`.
#[derive(Debug, Clone)]
pub struct UsageArgs {
    pub since: String,
    pub root: Option<PathBuf>,
    pub output: DelegateOutput,
}

#[derive(Debug, Clone, Serialize)]
struct DayUsage {
    date: String,
    delegation_count: u64,
    #[serde(flatten)]
    tokens: TokenUsage,
}

#[derive(Debug, Clone, Serialize)]
struct UsageReport {
    roots: Vec<PathBuf>,
    since: String,
    days: Vec<DayUsage>,
    total: TokenUsage,
    total_delegations: u64,
}

/// Show token usage across delegations, grouped by day.
///
/// Reads each delegation's manifest when it has one, and falls back to
/// re-parsing the raw stdout JSONL for delegations written before manifests
/// existed. That fallback is what lets sandboxes and JSONL be discarded without
/// erasing history: the manifest is written first, and it is what survives.
pub fn usage(args: UsageArgs) -> Result<(), LocusError> {
    let cutoff = parse_duration(&args.since)?;
    let roots = roots_to_scan(args.root);
    let now = SystemTime::now();
    let cutoff_epoch = now
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .saturating_sub(cutoff.as_secs());

    let mut day_map: BTreeMap<String, DayUsage> = BTreeMap::new();
    let mut total = TokenUsage::default();
    let mut total_delegations: u64 = 0;

    for root in &roots {
        let entries = fs::read_dir(root).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read delegations root: {}", e),
            path: root.clone(),
        })?;

        for item in entries {
            let dir_entry = item.map_err(|e| LocusError::Filesystem {
                message: format!("Failed to read entry: {}", e),
                path: root.clone(),
            })?;

            if !dir_entry.metadata().map(|m| m.is_dir()).unwrap_or(false) {
                continue;
            }

            let name = dir_entry.file_name().to_string_lossy().into_owned();
            let path = dir_entry.path();
            let manifest = read_manifest(&path);

            // The manifest carries its own completion time. Without one, fall
            // back to the millisecond timestamp encoded in the directory name.
            let ts_sec = match &manifest {
                Some(m) => m.completed_at,
                None => {
                    let Some(ts_ms) =
                        name.strip_prefix("delegate-").and_then(|s| s.parse::<u64>().ok())
                    else {
                        continue;
                    };
                    ts_ms / 1000
                }
            };
            if ts_sec < cutoff_epoch {
                continue;
            }

            let usage = match &manifest {
                Some(m) => m.usage.clone(),
                None => {
                    let jsonl_path = path.join(format!("{}-opencode-stdout.jsonl", name));
                    if jsonl_path.exists() {
                        extract_token_usage(&fs::read(&jsonl_path).unwrap_or_default())
                    } else {
                        None
                    }
                }
            };

            let date = format_epoch_date(ts_sec);
            total_delegations += 1;

            if let Some(u) = &usage {
                add_usage(&mut total, u);
            }

            let day = day_map.entry(date.clone()).or_insert_with(|| DayUsage {
                date,
                delegation_count: 0,
                tokens: TokenUsage::default(),
            });
            day.delegation_count += 1;
            if let Some(u) = &usage {
                add_usage(&mut day.tokens, u);
            }
        }
    }

    let days: Vec<DayUsage> = day_map.into_values().collect();
    let report = UsageReport {
        roots,
        since: args.since,
        days,
        total,
        total_delegations,
    };

    match args.output {
        DelegateOutput::Json => print_json(&report),
        DelegateOutput::Human => print_human_usage(&report),
    }
}

fn add_usage(total: &mut TokenUsage, u: &TokenUsage) {
    total.input_tokens += u.input_tokens;
    total.output_tokens += u.output_tokens;
    total.reasoning_tokens += u.reasoning_tokens;
    total.cache_read_tokens += u.cache_read_tokens;
    total.cache_write_tokens += u.cache_write_tokens;
    total.total_tokens += u.total_tokens;
    total.cost_usd += u.cost_usd;
}

fn format_epoch_date(epoch_secs: u64) -> String {
    Local
        .timestamp_opt(epoch_secs as i64, 0)
        .single()
        .map(|dt| dt.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

fn format_number(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}K", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn print_human_usage(report: &UsageReport) -> Result<(), LocusError> {
    output::print_header();
    output::section("Delegation Token Usage");
    output::field(
        "Roots",
        &report
            .roots
            .iter()
            .map(|r| r.display().to_string())
            .collect::<Vec<_>>()
            .join(", "),
    );
    output::field("Period", &format!("last {}", report.since));

    if report.days.is_empty() {
        output::info("No delegations found in the specified period.");
        return Ok(());
    }

    for day in &report.days {
        let label = format!(
            "{}  ({} delegation{})",
            day.date,
            day.delegation_count,
            if day.delegation_count == 1 { "" } else { "s" }
        );
        let detail = format!(
            "{} total  |  {} input, {} output, {} reasoning, {} cache read",
            format_number(day.tokens.total_tokens),
            format_number(day.tokens.input_tokens),
            format_number(day.tokens.output_tokens),
            format_number(day.tokens.reasoning_tokens),
            format_number(day.tokens.cache_read_tokens),
        );
        output::list_item(&label, &detail);
    }

    output::section("Total");
    output::field(
        "Delegations",
        &format!("{}", report.total_delegations),
    );
    output::field("Input tokens", &format_number(report.total.input_tokens));
    output::field("Output tokens", &format_number(report.total.output_tokens));
    output::field(
        "Reasoning tokens",
        &format_number(report.total.reasoning_tokens),
    );
    output::field(
        "Cache read tokens",
        &format_number(report.total.cache_read_tokens),
    );
    output::field("Total tokens", &format_number(report.total.total_tokens));

    Ok(())
}

/// Parse a duration spec like `7d`, `12h`, `30m`, `45s`.
fn parse_duration(spec: &str) -> Result<Duration, LocusError> {
    let trimmed = spec.trim();
    if trimmed.len() < 2 {
        return Err(invalid_duration(spec));
    }

    let (num_part, unit) = trimmed.split_at(trimmed.len() - 1);
    let value: u64 = num_part.parse().map_err(|_| invalid_duration(spec))?;

    let seconds = match unit {
        "s" => value,
        "m" => value.checked_mul(60).ok_or_else(|| invalid_duration(spec))?,
        "h" => value
            .checked_mul(3_600)
            .ok_or_else(|| invalid_duration(spec))?,
        "d" => value
            .checked_mul(86_400)
            .ok_or_else(|| invalid_duration(spec))?,
        _ => return Err(invalid_duration(spec)),
    };

    Ok(Duration::from_secs(seconds))
}

fn invalid_duration(spec: &str) -> LocusError {
    LocusError::Config {
        message: format!(
            "Invalid duration '{}'. Expected <number><unit> where unit is one of d, h, m, s.",
            spec
        ),
        path: None,
    }
}

fn print_human_ls(report: &LsReport) -> Result<(), LocusError> {
    output::print_header();
    output::section("Delegations");
    output::field(
        "Roots",
        &report
            .roots
            .iter()
            .map(|r| r.display().to_string())
            .collect::<Vec<_>>()
            .join(", "),
    );

    if report.entries.is_empty() {
        output::info("No delegation directories found.");
        return Ok(());
    }

    for entry in &report.entries {
        let label = format!("{} ({})", entry.id, format_age(entry.age_seconds));
        let description = format!(
            "{} total, {} in opencode-data",
            format_bytes(entry.size_bytes),
            format_bytes(entry.opencode_data_bytes)
        );
        output::list_item(&label, &description);
    }

    output::field(
        "Total",
        &format!(
            "{} across {} delegation(s)",
            format_bytes(report.total_bytes),
            report.entries.len()
        ),
    );
    Ok(())
}

fn print_human_prune(report: &PruneReport) -> Result<(), LocusError> {
    output::print_header();
    let title = if report.applied {
        "Delegation Prune (applied)"
    } else {
        "Delegation Prune (dry-run)"
    };
    output::section(title);
    output::field(
        "Roots",
        &report
            .roots
            .iter()
            .map(|r| r.display().to_string())
            .collect::<Vec<_>>()
            .join(", "),
    );
    output::field(
        "Mode",
        if report.keep_stdout {
            "keep stdout/stderr artifacts"
        } else {
            "remove entire delegation dirs"
        },
    );

    if report.selected.is_empty() {
        output::info("No delegations matched the selection.");
        return Ok(());
    }

    for entry in &report.selected {
        let label = format!("{} ({})", entry.id, format_age(entry.age_seconds));
        output::list_item(&label, &format_bytes(entry.size_bytes));
    }

    let summary = if report.applied {
        format!(
            "Freed {} across {} delegation(s).",
            format_bytes(report.freed_bytes),
            report.selected.len()
        )
    } else {
        format!(
            "Would free {} across {} delegation(s). Re-run with --apply to delete.",
            format_bytes(report.freed_bytes),
            report.selected.len()
        )
    };
    output::field("Result", &summary);
    Ok(())
}

fn format_age(seconds: u64) -> String {
    if seconds < 60 {
        format!("{}s ago", seconds)
    } else if seconds < 3_600 {
        format!("{}m ago", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h ago", seconds / 3_600)
    } else {
        format!("{}d ago", seconds / 86_400)
    }
}

fn format_bytes(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = 1024 * KB;
    const GB: u64 = 1024 * MB;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn sample_args() -> RunArgs {
        RunArgs {
            backend: DelegateBackendArg::Opencode,
            task_kind: DelegateTaskKindArg::Research,
            model: Some("openai/gpt-5.5".into()),
            dir: PathBuf::from("/tmp/project"),
            prompt: "Research a topic".into(),
            agent: Some("research".into()),
            variant: Some("high".into()),
            context_files: vec![PathBuf::from("/tmp/context.md")],
            artifact_dir: Some(PathBuf::from("/tmp/artifacts")),
            timeout_seconds: 600,
            dry_run: true,
            output: DelegateOutput::Json,
            mode: ExecutionModeArg::Native,
        }
    }

    fn empty_config() -> DelegationConfig {
        DelegationConfig::default()
    }

    fn config_with_research_default(model: &str) -> DelegationConfig {
        let mut inner = HashMap::new();
        inner.insert(
            "research".to_string(),
            DelegationDefaults {
                model: model.into(),
                variant: Some("low".into()),
                agent: Some("default-agent".into()),
            },
        );
        let mut outer = HashMap::new();
        outer.insert("opencode".to_string(), inner);
        DelegationConfig { enabled: true, defaults: outer }
    }

    #[test]
    fn build_request_enforces_read_only_mode() {
        let request = build_request(sample_args(), &empty_config()).unwrap();

        assert_eq!(request.backend, DelegationBackend::OpenCode);
        assert_eq!(request.task_kind, DelegationTaskKind::Research);
        assert_eq!(request.mode, DelegationMode::ReadOnly);
        assert_eq!(
            request.output_schema_version,
            DelegationRequest::CURRENT_SCHEMA_VERSION
        );
    }

    #[test]
    fn build_request_keeps_context_files() {
        let request = build_request(sample_args(), &empty_config()).unwrap();

        assert_eq!(
            request.context_files,
            vec![PathBuf::from("/tmp/context.md")]
        );
        assert_eq!(request.artifact_dir, PathBuf::from("/tmp/artifacts"));
    }

    #[test]
    fn validate_request_rejects_zero_timeout() {
        let mut request = build_request(sample_args(), &empty_config()).unwrap();
        request.timeout_seconds = 0;

        assert!(validate_request(&request).is_err());
    }

    fn unique_root() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("locus-delegate-test-{}", nanos))
    }

    fn write_delegation(
        root: &Path,
        id: &str,
        files: &[(&str, &[u8])],
        opencode_files: &[(&str, &[u8])],
    ) -> PathBuf {
        let dir = root.join(id);
        fs::create_dir_all(&dir).unwrap();
        for (name, content) in files {
            fs::write(dir.join(name), content).unwrap();
        }
        if !opencode_files.is_empty() {
            let opencode = dir.join("opencode-data");
            fs::create_dir_all(&opencode).unwrap();
            for (name, content) in opencode_files {
                fs::write(opencode.join(name), content).unwrap();
            }
        }
        dir
    }

    #[test]
    fn parse_duration_accepts_valid_units() {
        assert_eq!(parse_duration("30s").unwrap(), Duration::from_secs(30));
        assert_eq!(parse_duration("5m").unwrap(), Duration::from_secs(300));
        assert_eq!(parse_duration("2h").unwrap(), Duration::from_secs(7_200));
        assert_eq!(parse_duration("3d").unwrap(), Duration::from_secs(259_200));
    }

    #[test]
    fn parse_duration_rejects_malformed_input() {
        assert!(parse_duration("").is_err());
        assert!(parse_duration("d").is_err());
        assert!(parse_duration("7").is_err());
        assert!(parse_duration("7w").is_err());
        assert!(parse_duration("-1d").is_err());
        assert!(parse_duration("abc").is_err());
    }

    /// Write a delegation directory that also carries a credential copy, the
    /// way every pre-DEV-505 delegation did.
    fn write_delegation_with_auth(root: &Path, id: &str) -> PathBuf {
        let dir = write_delegation(
            root,
            id,
            &[(&format!("{}-opencode-stdout.jsonl", id), b"{}")],
            &[("opencode.db", &[0u8; 2048])],
        );
        let auth_dir = dir.join("opencode-data").join("opencode");
        fs::create_dir_all(&auth_dir).unwrap();
        fs::write(auth_dir.join("auth.json"), br#"{"openai":{"expires":1}}"#).unwrap();
        dir
    }

    fn write_manifest_file(dir: &Path, id: &str, completed_at: u64, total_tokens: u64) {
        let manifest = serde_json::json!({
            "schema_version": 1,
            "id": id,
            "backend": "opencode",
            "task_kind": "research",
            "model": "openai/gpt-5.6-sol",
            "status": "success",
            "completed_at": completed_at,
            "duration_ms": 1234,
            "usage": {
                "input_tokens": 10,
                "output_tokens": 20,
                "reasoning_tokens": 0,
                "cache_read_tokens": 0,
                "cache_write_tokens": 0,
                "total_tokens": total_tokens,
                "cost_usd": 0.5
            },
            "sandbox_discarded": true
        });
        fs::write(
            dir.join(DelegationManifest::FILE_NAME),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
    }

    /// DEV-505: the default root moved out of the memory tree. Delegation
    /// scratch is ephemeral; memory is not.
    #[test]
    fn default_root_is_not_inside_memory_work() {
        let root = default_delegations_root();
        assert!(
            !root.to_string_lossy().contains("memory"),
            "delegation scratch must not live in the memory tree: {}",
            root.display()
        );
        assert!(root.ends_with("data/delegations"), "got {}", root.display());
    }

    /// DEV-505: the pre-move root is still walked, or the existing 225
    /// delegations become invisible to ls, prune, and usage.
    #[test]
    fn legacy_root_is_still_scanned() {
        assert!(legacy_delegations_root()
            .to_string_lossy()
            .contains("memory/work/delegations"));
        // An explicit --root is taken literally and suppresses both defaults.
        let explicit = PathBuf::from("/tmp/somewhere");
        assert_eq!(roots_to_scan(Some(explicit.clone())), vec![explicit]);
    }

    /// DEV-505: "no auth.json copy survives a prune, regardless of age."
    #[test]
    fn prune_removes_credential_copies_regardless_of_age() {
        let root = unique_root();
        let dir = write_delegation_with_auth(&root, "delegate-auth1");
        let auth = auth_copy_path(&dir);
        assert!(auth.exists());

        // Selected by age: nothing here is 30 days old, so the entry itself is
        // not pruned — but the credential copy must still go.
        prune(PruneArgs {
            older_than: Some("30d".into()),
            all: false,
            sandboxes: false,
            apply: true,
            keep_stdout: false,
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        assert!(dir.exists(), "a young delegation is not deleted by --older-than 30d");
        assert!(!auth.exists(), "the credential copy must be purged anyway");

        fs::remove_dir_all(&root).ok();
    }

    /// DEV-505: a symlink to the canonical credential is not a copy, and must
    /// never be followed and deleted — that would destroy the real file.
    #[cfg(unix)]
    #[test]
    fn prune_does_not_delete_the_canonical_file_through_a_link() {
        let root = unique_root();
        let canonical = root.join("canonical-auth.json");
        fs::create_dir_all(&root).unwrap();
        fs::write(&canonical, br#"{"openai":{"expires":9}}"#).unwrap();

        let dir = write_delegation(&root, "delegate-link", &[], &[]);
        let auth_dir = dir.join("opencode-data").join("opencode");
        fs::create_dir_all(&auth_dir).unwrap();
        std::os::unix::fs::symlink(&canonical, auth_dir.join("auth.json")).unwrap();

        purge_auth_files(&root).unwrap();

        assert!(
            canonical.exists(),
            "the canonical credential must survive — the link is removed, not its target"
        );
        fs::remove_dir_all(&root).ok();
    }

    /// DEV-505: the one-shot repair for the 225 existing sandboxes. Strips the
    /// sandbox from every entry of any age while keeping the manifest and the
    /// stdout artifact.
    #[test]
    fn prune_sandboxes_strips_sandboxes_but_keeps_artifacts() {
        let root = unique_root();
        let dir = write_delegation_with_auth(&root, "delegate-repair");
        write_manifest_file(&dir, "delegate-repair", 1_788_000_000, 30);
        fs::create_dir_all(dir.join("opencode-cache")).unwrap();
        fs::write(dir.join("opencode-cache").join("models.json"), [0u8; 512]).unwrap();

        prune(PruneArgs {
            older_than: None,
            all: false,
            sandboxes: true,
            apply: true,
            keep_stdout: false,
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        for name in SANDBOX_DIRS {
            assert!(!dir.join(name).exists(), "{} must be stripped", name);
        }
        assert!(
            dir.join("delegate-repair-opencode-stdout.jsonl").exists(),
            "stdout artifact is kept"
        );
        assert!(
            dir.join(DelegationManifest::FILE_NAME).exists(),
            "the manifest must survive — usage history depends on it"
        );

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn prune_rejects_more_than_one_selector() {
        let result = prune(PruneArgs {
            older_than: None,
            all: true,
            sandboxes: true,
            apply: false,
            keep_stdout: false,
            root: Some(unique_root()),
            output: DelegateOutput::Json,
        });
        assert!(result.is_err());
    }

    /// DEV-505 ordering guarantee: usage is computed from the manifest, so a
    /// delegation whose sandbox and JSONL are gone still reports its tokens.
    #[test]
    fn usage_reads_the_manifest_when_the_jsonl_is_gone() {
        let root = unique_root();
        let dir = root.join("delegate-manifest-only");
        fs::create_dir_all(&dir).unwrap();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        write_manifest_file(&dir, "delegate-manifest-only", now, 4242);

        let manifest = read_manifest(&dir).expect("manifest parses");
        assert_eq!(manifest.usage.unwrap().total_tokens, 4242);

        // And the report path runs clean over a manifest-only directory.
        usage(UsageArgs {
            since: "30d".into(),
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        fs::remove_dir_all(&root).ok();
    }

    /// The fallback that keeps pre-manifest delegations countable.
    #[test]
    fn usage_falls_back_to_jsonl_for_legacy_delegations() {
        let root = unique_root();
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let id = format!("delegate-{}", now_ms);
        let dir = write_delegation(&root, &id, &[], &[]);
        assert!(read_manifest(&dir).is_none(), "legacy dirs have no manifest");

        usage(UsageArgs {
            since: "1d".into(),
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        fs::remove_dir_all(&root).ok();
    }

    /// DEV-505: the retention sweep keeps the manifest and drops the bulk.
    #[test]
    fn sweep_expired_keeps_the_manifest_and_drops_the_rest() {
        let root = unique_root();
        let dir = write_delegation_with_auth(&root, "delegate-old");
        write_manifest_file(&dir, "delegate-old", 1, 7);

        // Pretend "now" is far past the retention window.
        let future = SystemTime::now() + Duration::from_secs(RETENTION_DAYS * 86_400 + 3_600);
        sweep_expired(&root, future).unwrap();

        assert!(dir.join(DelegationManifest::FILE_NAME).exists());
        assert!(!dir.join("opencode-data").exists());
        assert!(!dir.join("delegate-old-opencode-stdout.jsonl").exists());

        fs::remove_dir_all(&root).ok();
    }

    /// A delegation with no manifest is never swept — the JSONL would be the
    /// only surviving evidence it ever ran.
    #[test]
    fn sweep_expired_spares_entries_without_a_manifest() {
        let root = unique_root();
        let dir = write_delegation(
            &root,
            "delegate-nomanifest",
            &[("delegate-nomanifest-opencode-stdout.jsonl", b"{}")],
            &[],
        );

        let future = SystemTime::now() + Duration::from_secs(RETENTION_DAYS * 86_400 + 3_600);
        sweep_expired(&root, future).unwrap();

        assert!(dir.join("delegate-nomanifest-opencode-stdout.jsonl").exists());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn enumerate_returns_empty_for_missing_root() {
        let root = unique_root();
        let entries = enumerate_delegations(&root, SystemTime::now()).unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn enumerate_reports_size_and_opencode_breakdown() {
        let root = unique_root();
        write_delegation(
            &root,
            "delegate-aaa",
            &[("delegate-aaa-opencode-stdout.jsonl", b"hello world")],
            &[("opencode.db", &[0u8; 4096])],
        );

        let entries = enumerate_delegations(&root, SystemTime::now()).unwrap();
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];
        assert_eq!(entry.id, "delegate-aaa");
        assert_eq!(entry.opencode_data_bytes, 4096);
        assert_eq!(entry.size_bytes, 4096 + 11);

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn prune_dry_run_does_not_delete() {
        let root = unique_root();
        let dir = write_delegation(
            &root,
            "delegate-bbb",
            &[("delegate-bbb-opencode-stdout.jsonl", b"x")],
            &[("opencode.db", &[0u8; 1024])],
        );

        prune(PruneArgs {
            older_than: None,
            all: true,
            sandboxes: false,
            apply: false,
            keep_stdout: false,
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        assert!(dir.exists(), "dry-run must not delete the delegation dir");

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn prune_apply_removes_entire_dir() {
        let root = unique_root();
        let dir = write_delegation(
            &root,
            "delegate-ccc",
            &[("delegate-ccc-opencode-stdout.jsonl", b"x")],
            &[("opencode.db", &[0u8; 1024])],
        );

        prune(PruneArgs {
            older_than: None,
            all: true,
            sandboxes: false,
            apply: true,
            keep_stdout: false,
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        assert!(!dir.exists(), "apply must remove the delegation dir");

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn prune_keep_stdout_retains_artifacts_and_removes_data() {
        let root = unique_root();
        let id = "delegate-ddd";
        let dir = write_delegation(
            &root,
            id,
            &[
                (
                    &format!("{}-opencode-stdout.jsonl", id),
                    b"final answer json",
                ),
                (
                    &format!("{}-opencode-stderr.log", id),
                    b"warning emitted",
                ),
            ],
            &[("opencode.db", &[0u8; 2048])],
        );

        prune(PruneArgs {
            older_than: None,
            all: true,
            sandboxes: false,
            apply: true,
            keep_stdout: true,
            root: Some(root.clone()),
            output: DelegateOutput::Json,
        })
        .unwrap();

        assert!(dir.exists(), "delegation dir must remain");
        assert!(
            dir.join(format!("{}-opencode-stdout.jsonl", id)).exists(),
            "stdout artifact must be kept"
        );
        assert!(
            dir.join(format!("{}-opencode-stderr.log", id)).exists(),
            "stderr artifact must be kept"
        );
        assert!(
            !dir.join("opencode-data").exists(),
            "opencode-data must be removed"
        );

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn enumerate_filters_by_age_using_now() {
        let root = unique_root();
        write_delegation(
            &root,
            "delegate-young",
            &[("delegate-young-opencode-stdout.jsonl", b"x")],
            &[],
        );
        write_delegation(
            &root,
            "delegate-mid",
            &[("delegate-mid-opencode-stdout.jsonl", b"x")],
            &[],
        );

        // Simulate "now" two hours into the future so all dirs are 2h+ old.
        let future_now = SystemTime::now() + Duration::from_secs(7_200);
        let entries = enumerate_delegations(&root, future_now).unwrap();
        assert_eq!(entries.len(), 2);

        let cutoff = parse_duration("1h").unwrap();
        let aged: Vec<_> = entries
            .iter()
            .filter(|e| e.age_seconds >= cutoff.as_secs())
            .collect();
        assert_eq!(aged.len(), 2, "both dirs are >1h old in simulated time");

        let cutoff_strict = parse_duration("3h").unwrap();
        let aged_strict: Vec<_> = entries
            .iter()
            .filter(|e| e.age_seconds >= cutoff_strict.as_secs())
            .collect();
        assert!(
            aged_strict.is_empty(),
            "no dir is >3h old in simulated time"
        );

        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn prune_rejects_no_selector() {
        let result = prune(PruneArgs {
            older_than: None,
            all: false,
            sandboxes: false,
            apply: false,
            keep_stdout: false,
            root: Some(unique_root()),
            output: DelegateOutput::Json,
        });
        assert!(result.is_err());
    }

    #[test]
    fn prune_rejects_both_selectors() {
        let result = prune(PruneArgs {
            older_than: Some("1d".into()),
            all: true,
            sandboxes: false,
            apply: false,
            keep_stdout: false,
            root: Some(unique_root()),
            output: DelegateOutput::Json,
        });
        assert!(result.is_err());
    }

    #[test]
    fn build_request_uses_cli_model_when_provided() {
        let mut args = sample_args();
        args.model = Some("openai/gpt-4o".into());
        let request = build_request(args, &empty_config()).unwrap();
        assert_eq!(request.model, "openai/gpt-4o");
    }

    #[test]
    fn build_request_uses_config_default_when_no_cli_model() {
        let mut args = sample_args();
        args.model = None;
        let config = config_with_research_default("openai/gpt-5.4-mini");
        let request = build_request(args, &config).unwrap();
        assert_eq!(request.model, "openai/gpt-5.4-mini");
    }

    #[test]
    fn build_request_falls_back_to_hardcoded_model() {
        let mut args = sample_args();
        args.model = None;
        let request = build_request(args, &empty_config()).unwrap();
        assert_eq!(request.model, "openai/gpt-5.6-sol");
    }

    #[test]
    fn build_request_cli_model_overrides_config() {
        let mut args = sample_args();
        args.model = Some("openai/gpt-4o".into());
        let config = config_with_research_default("openai/gpt-5.4-mini");
        let request = build_request(args, &config).unwrap();
        assert_eq!(request.model, "openai/gpt-4o");
    }

    #[test]
    fn build_request_propagates_native_mode_by_default() {
        let request = build_request(sample_args(), &empty_config()).unwrap();
        assert_eq!(request.execution_mode, ExecutionMode::Native);
    }

    #[test]
    fn build_request_propagates_algorithmic_mode_when_set() {
        let mut args = sample_args();
        args.mode = ExecutionModeArg::Algorithmic;
        let request = build_request(args, &empty_config()).unwrap();
        assert_eq!(request.execution_mode, ExecutionMode::Algorithmic);
    }
}
