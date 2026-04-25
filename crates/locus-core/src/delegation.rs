//! Delegation request and result schemas.
//!
//! These types are the stable boundary between an interactive orchestrator
//! and an external execution backend such as OpenCode.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// External backend used to execute a delegated task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationBackend {
    /// OpenCode CLI backed by its configured providers.
    #[serde(rename = "opencode")]
    OpenCode,
}

impl DelegationBackend {
    /// Stable string used in CLI messages and prompts.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::OpenCode => "opencode",
        }
    }
}

/// Broad category of delegated work.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationTaskKind {
    /// Research using web/docs/code sources.
    Research,
    /// Read-only inspection of a codebase.
    CodeExploration,
    /// General bounded execution task.
    General,
}

impl DelegationTaskKind {
    /// Stable string used in prompts.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Research => "research",
            Self::CodeExploration => "code_exploration",
            Self::General => "general",
        }
    }
}

/// Safety mode for delegated execution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationMode {
    /// The delegated backend must not modify files or persistent state.
    ReadOnly,
}

/// Orchestration-context mode for a spawned session.
///
/// `Native` sessions run with no Locus orchestration scaffolding loaded — bare
/// model + tools, intended for bounded execution (delegation, council members,
/// red-team attackers). `Algorithmic` sessions load the full Algorithm and
/// skill machinery — intended for the top-level orchestrator.
///
/// Orthogonal to `DelegationMode` (read-only vs write-isolated). A request
/// can be `(Native, ReadOnly)` or in future `(Algorithmic, WriteIsolated)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    /// Bare session — no Algorithm, no Mode Classification, no skills load.
    Native,
    /// Full Locus orchestration loaded into the session.
    Algorithmic,
}

impl Default for ExecutionMode {
    fn default() -> Self {
        Self::Native
    }
}

impl ExecutionMode {
    /// Stable string used in CLI parsing and prompts.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Algorithmic => "algorithmic",
        }
    }
}

/// Completion status for a delegated task.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationStatus {
    /// Backend exited successfully.
    Success,
    /// Backend exited with an error or could not start.
    Failure,
    /// Backend exceeded the configured timeout.
    TimedOut,
}

/// Stable input contract for delegated execution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegationRequest {
    /// Unique request identifier.
    pub id: String,
    /// Backend that will execute the task.
    pub backend: DelegationBackend,
    /// Broad delegated task category.
    pub task_kind: DelegationTaskKind,
    /// Provider/model identifier passed to the backend.
    pub model: String,
    /// Optional backend agent/profile name.
    #[serde(default)]
    pub agent: Option<String>,
    /// Optional provider-specific reasoning variant.
    #[serde(default)]
    pub variant: Option<String>,
    /// Workspace directory the backend should run in.
    pub workspace_dir: PathBuf,
    /// User-level task prompt.
    pub prompt: String,
    /// Files attached as bounded context.
    #[serde(default)]
    pub context_files: Vec<PathBuf>,
    /// Safety mode for this request (read-only vs hypothetical write-isolated).
    pub mode: DelegationMode,
    /// Orchestration-context mode for the spawned session. Defaults to
    /// `Native`: delegated work is bounded execution and should NOT inherit
    /// the Locus Algorithm. Set to `Algorithmic` only when the delegated
    /// session itself needs to orchestrate.
    #[serde(default)]
    pub execution_mode: ExecutionMode,
    /// Result schema version expected by the caller.
    pub output_schema_version: u32,
    /// Directory where raw backend artifacts are written.
    pub artifact_dir: PathBuf,
    /// Maximum execution time in seconds.
    pub timeout_seconds: u64,
}

impl DelegationRequest {
    /// Initial schema version for the prototype request/result contract.
    pub const CURRENT_SCHEMA_VERSION: u32 = 1;

    /// Returns true when the request uses the only currently supported mode.
    pub fn is_read_only(&self) -> bool {
        self.mode == DelegationMode::ReadOnly
    }
}

/// Stable output contract for delegated execution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegationResult {
    /// Unique request identifier.
    pub id: String,
    /// Completion status.
    pub status: DelegationStatus,
    /// Backend that executed the task.
    pub backend: DelegationBackend,
    /// Provider/model identifier used by the backend.
    pub model: String,
    /// Compact result summary safe for the orchestrator context.
    pub summary: String,
    /// Important findings extracted by the runner, if available.
    #[serde(default)]
    pub findings: Vec<String>,
    /// Evidence references extracted by the runner, if available.
    #[serde(default)]
    pub evidence: Vec<String>,
    /// Risks or limitations identified during execution.
    #[serde(default)]
    pub risks: Vec<String>,
    /// Files referenced by the delegated result.
    #[serde(default)]
    pub files_referenced: Vec<String>,
    /// Artifact paths produced by the runner.
    #[serde(default)]
    pub artifacts: Vec<PathBuf>,
    /// Path to the raw stdout artifact, when present.
    #[serde(default)]
    pub raw_output_path: Option<PathBuf>,
    /// Execution duration in milliseconds.
    pub duration_ms: u64,
    /// Structured error message for failures.
    #[serde(default)]
    pub error: Option<String>,
}

impl DelegationResult {
    /// Build a compact success result.
    pub fn success(request: &DelegationRequest, summary: String, duration_ms: u64) -> Self {
        Self {
            id: request.id.clone(),
            status: DelegationStatus::Success,
            backend: request.backend.clone(),
            model: request.model.clone(),
            summary,
            findings: Vec::new(),
            evidence: Vec::new(),
            risks: Vec::new(),
            files_referenced: Vec::new(),
            artifacts: Vec::new(),
            raw_output_path: None,
            duration_ms,
            error: None,
        }
    }

    /// Build a compact failure result.
    pub fn failure(
        request: &DelegationRequest,
        status: DelegationStatus,
        message: String,
        duration_ms: u64,
    ) -> Self {
        Self {
            id: request.id.clone(),
            status,
            backend: request.backend.clone(),
            model: request.model.clone(),
            summary: message.clone(),
            findings: Vec::new(),
            evidence: Vec::new(),
            risks: Vec::new(),
            files_referenced: Vec::new(),
            artifacts: Vec::new(),
            raw_output_path: None,
            duration_ms,
            error: Some(message),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_request() -> DelegationRequest {
        DelegationRequest {
            id: "delegate-test".into(),
            backend: DelegationBackend::OpenCode,
            task_kind: DelegationTaskKind::Research,
            model: "openai/gpt-5.5".into(),
            agent: Some("research".into()),
            variant: Some("high".into()),
            workspace_dir: PathBuf::from("/tmp/project"),
            prompt: "Research the topic".into(),
            context_files: vec![PathBuf::from("/tmp/context.md")],
            mode: DelegationMode::ReadOnly,
            execution_mode: ExecutionMode::Native,
            output_schema_version: DelegationRequest::CURRENT_SCHEMA_VERSION,
            artifact_dir: PathBuf::from("/tmp/artifacts"),
            timeout_seconds: 600,
        }
    }

    #[test]
    fn request_serializes_stable_backend_and_mode() {
        let json = serde_json::to_value(sample_request()).unwrap();

        assert_eq!(json["backend"], "opencode");
        assert_eq!(json["task_kind"], "research");
        assert_eq!(json["mode"], "read_only");
        assert_eq!(json["execution_mode"], "native");
        assert_eq!(json["output_schema_version"], 1);
    }

    #[test]
    fn execution_mode_default_is_native() {
        assert_eq!(ExecutionMode::default(), ExecutionMode::Native);
    }

    #[test]
    fn execution_mode_field_is_optional_in_serde() {
        // Older request payloads (pre-execution-mode field) must still parse,
        // defaulting to Native.
        let json = r#"{
            "id": "x",
            "backend": "opencode",
            "task_kind": "research",
            "model": "openai/gpt-5.5",
            "workspace_dir": "/tmp/p",
            "prompt": "hi",
            "mode": "read_only",
            "output_schema_version": 1,
            "artifact_dir": "/tmp/a",
            "timeout_seconds": 60
        }"#;
        let parsed: DelegationRequest = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.execution_mode, ExecutionMode::Native);
    }

    #[test]
    fn request_roundtrips_from_json() {
        let request = sample_request();
        let json = serde_json::to_string(&request).unwrap();
        let parsed: DelegationRequest = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed, request);
        assert!(parsed.is_read_only());
    }

    #[test]
    fn result_serializes_stable_status() {
        let request = sample_request();
        let mut result = DelegationResult::success(&request, "done".into(), 42);
        result.raw_output_path = Some(PathBuf::from("/tmp/raw.jsonl"));

        let json = serde_json::to_value(result).unwrap();

        assert_eq!(json["status"], "success");
        assert_eq!(json["backend"], "opencode");
        assert_eq!(json["duration_ms"], 42);
        assert_eq!(json["raw_output_path"], "/tmp/raw.jsonl");
    }

    #[test]
    fn failure_result_carries_error_message() {
        let request = sample_request();
        let result = DelegationResult::failure(
            &request,
            DelegationStatus::Failure,
            "backend failed".into(),
            7,
        );

        assert_eq!(result.status, DelegationStatus::Failure);
        assert_eq!(result.error.as_deref(), Some("backend failed"));
        assert_eq!(result.summary, "backend failed");
    }
}
