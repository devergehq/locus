//! `locus delegate ...` — external execution delegation.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::ValueEnum;
use locus_adapter_opencode::run::run_delegation;
use locus_core::{
    DelegationBackend, DelegationConfig, DelegationDefaults, DelegationMode, DelegationRequest,
    DelegationTaskKind, ExecutionMode, LocusConfig, LocusError,
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

fn resolve_model(
    cli_model: Option<&str>,
    defaults: Option<&DelegationDefaults>,
    backend: &DelegationBackend,
    task_kind: &DelegationTaskKind,
) -> Result<String, LocusError> {
    if let Some(m) = cli_model.map(str::trim).filter(|s| !s.is_empty()) {
        return Ok(m.to_string());
    }
    if let Some(default) = defaults {
        return Ok(default.model.clone());
    }
    Err(LocusError::Config {
        message: format!(
            "No --model provided and no delegation default configured for ({}, {}). Either pass --model or set delegation.defaults.{}.{}.model in ~/.locus/locus.yaml.",
            backend.as_str(),
            task_kind.as_str(),
            backend.as_str(),
            task_kind.as_str()
        ),
        path: None,
    })
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

fn default_delegations_root() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".locus")
        .join("data")
        .join("memory")
        .join("work")
        .join("delegations")
}

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
    pub apply: bool,
    pub keep_stdout: bool,
    pub root: Option<PathBuf>,
    pub output: DelegateOutput,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
struct DelegationEntry {
    id: String,
    path: PathBuf,
    age_seconds: u64,
    size_bytes: u64,
    opencode_data_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
struct LsReport {
    root: PathBuf,
    entries: Vec<DelegationEntry>,
    total_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
struct PruneReport {
    root: PathBuf,
    applied: bool,
    keep_stdout: bool,
    selected: Vec<DelegationEntry>,
    freed_bytes: u64,
}

/// List existing delegation artifact directories.
pub fn ls(args: LsArgs) -> Result<(), LocusError> {
    let root = args.root.unwrap_or_else(default_delegations_root);
    let entries = enumerate_delegations(&root, SystemTime::now())?;
    let total_bytes = entries.iter().map(|e| e.size_bytes).sum();

    let report = LsReport {
        root,
        entries,
        total_bytes,
    };

    match args.output {
        DelegateOutput::Json => print_json(&report),
        DelegateOutput::Human => print_human_ls(&report),
    }
}

/// Prune delegation artifact directories.
pub fn prune(args: PruneArgs) -> Result<(), LocusError> {
    if args.all == args.older_than.is_some() {
        return Err(LocusError::Config {
            message: "Specify exactly one of --all or --older-than".into(),
            path: None,
        });
    }

    let cutoff = match &args.older_than {
        Some(spec) => Some(parse_duration(spec)?),
        None => None,
    };

    let root = args.root.unwrap_or_else(default_delegations_root);
    let now = SystemTime::now();
    let all_entries = enumerate_delegations(&root, now)?;

    let selected: Vec<DelegationEntry> = all_entries
        .into_iter()
        .filter(|entry| match &cutoff {
            Some(min_age) => entry.age_seconds >= min_age.as_secs(),
            None => true,
        })
        .collect();

    let mut freed_bytes: u64 = 0;
    if args.apply {
        for entry in &selected {
            freed_bytes += delete_entry(&entry.path, args.keep_stdout, &entry.id)?;
        }
    } else {
        freed_bytes = selected.iter().map(|e| e.size_bytes).sum();
    }

    let report = PruneReport {
        root,
        applied: args.apply,
        keep_stdout: args.keep_stdout,
        selected,
        freed_bytes,
    };

    match args.output {
        DelegateOutput::Json => print_json(&report),
        DelegateOutput::Human => print_human_prune(&report),
    }
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
        let mtime = metadata.modified().unwrap_or(UNIX_EPOCH);
        let age_seconds = now.duration_since(mtime).map(|d| d.as_secs()).unwrap_or(0);

        entries.push(DelegationEntry {
            id,
            path,
            age_seconds,
            size_bytes,
            opencode_data_bytes,
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
    output::field("Root", &report.root.display().to_string());

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
    output::field("Root", &report.root.display().to_string());
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
        DelegationConfig { defaults: outer }
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
            apply: false,
            keep_stdout: false,
            root: Some(unique_root()),
            output: DelegateOutput::Json,
        });
        assert!(result.is_err());
    }

    #[test]
    fn build_request_resolves_model_from_config_when_cli_omits_it() {
        let mut args = sample_args();
        args.model = None;
        args.agent = None;
        args.variant = None;

        let config = config_with_research_default("openai/gpt-5.4-mini");
        let request = build_request(args, &config).unwrap();

        assert_eq!(request.model, "openai/gpt-5.4-mini");
        assert_eq!(request.agent.as_deref(), Some("default-agent"));
        assert_eq!(request.variant.as_deref(), Some("low"));
    }

    #[test]
    fn build_request_errors_when_no_model_and_no_default() {
        let mut args = sample_args();
        args.model = None;

        let err = build_request(args, &empty_config()).unwrap_err();
        let message = err.to_string();
        assert!(message.contains("No --model provided"));
        assert!(message.contains("delegation.defaults.opencode.research"));
    }

    #[test]
    fn build_request_cli_model_overrides_config_default() {
        let args = sample_args();
        let config = config_with_research_default("openai/gpt-5.4-mini");
        let request = build_request(args, &config).unwrap();

        assert_eq!(request.model, "openai/gpt-5.5");
        // CLI agent/variant also win since they were Some in sample_args.
        assert_eq!(request.agent.as_deref(), Some("research"));
        assert_eq!(request.variant.as_deref(), Some("high"));
    }

    #[test]
    fn build_request_treats_empty_model_string_as_unset() {
        let mut args = sample_args();
        args.model = Some("   ".into());
        let config = config_with_research_default("openai/gpt-5.4-mini");
        let request = build_request(args, &config).unwrap();

        assert_eq!(request.model, "openai/gpt-5.4-mini");
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
