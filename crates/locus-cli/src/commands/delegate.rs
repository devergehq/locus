//! `locus delegate ...` — external execution delegation.

use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::ValueEnum;
use locus_adapter_opencode::run::run_delegation;
use locus_core::{
    DelegationBackend, DelegationMode, DelegationRequest, DelegationTaskKind, LocusError,
};

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

/// Arguments for `locus delegate run`.
#[derive(Debug, Clone)]
pub struct RunArgs {
    pub backend: DelegateBackendArg,
    pub task_kind: DelegateTaskKindArg,
    pub model: String,
    pub dir: PathBuf,
    pub prompt: String,
    pub agent: Option<String>,
    pub variant: Option<String>,
    pub context_files: Vec<PathBuf>,
    pub artifact_dir: Option<PathBuf>,
    pub timeout_seconds: u64,
    pub dry_run: bool,
    pub output: DelegateOutput,
}

/// Run a delegated task through the selected backend.
pub fn run(args: RunArgs) -> Result<(), LocusError> {
    let dry_run = args.dry_run;
    let output_mode = args.output;
    let request = build_request(args)?;
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

fn build_request(args: RunArgs) -> Result<DelegationRequest, LocusError> {
    let id = new_request_id();
    let artifact_dir = args
        .artifact_dir
        .unwrap_or_else(|| default_artifact_dir(&id));

    Ok(DelegationRequest {
        id,
        backend: args.backend.into(),
        task_kind: args.task_kind.into(),
        model: args.model,
        agent: args.agent,
        variant: args.variant,
        workspace_dir: args.dir,
        prompt: args.prompt,
        context_files: args.context_files,
        mode: DelegationMode::ReadOnly,
        output_schema_version: DelegationRequest::CURRENT_SCHEMA_VERSION,
        artifact_dir,
        timeout_seconds: args.timeout_seconds,
    })
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
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".locus")
        .join("data")
        .join("memory")
        .join("work")
        .join("delegations")
        .join(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_args() -> RunArgs {
        RunArgs {
            backend: DelegateBackendArg::Opencode,
            task_kind: DelegateTaskKindArg::Research,
            model: "openai/gpt-5.5".into(),
            dir: PathBuf::from("/tmp/project"),
            prompt: "Research a topic".into(),
            agent: Some("research".into()),
            variant: Some("high".into()),
            context_files: vec![PathBuf::from("/tmp/context.md")],
            artifact_dir: Some(PathBuf::from("/tmp/artifacts")),
            timeout_seconds: 600,
            dry_run: true,
            output: DelegateOutput::Json,
        }
    }

    #[test]
    fn build_request_enforces_read_only_mode() {
        let request = build_request(sample_args()).unwrap();

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
        let request = build_request(sample_args()).unwrap();

        assert_eq!(
            request.context_files,
            vec![PathBuf::from("/tmp/context.md")]
        );
        assert_eq!(request.artifact_dir, PathBuf::from("/tmp/artifacts"));
    }

    #[test]
    fn validate_request_rejects_zero_timeout() {
        let mut request = build_request(sample_args()).unwrap();
        request.timeout_seconds = 0;

        assert!(validate_request(&request).is_err());
    }
}
