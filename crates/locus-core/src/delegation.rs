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

/// Token usage from a delegated execution.
///
/// Fields are cumulative across all steps in the session. The `input_tokens`
/// count excludes cached tokens — those are tracked separately in
/// `cache_read_tokens`. The relationship is:
/// `total_tokens = input_tokens + output_tokens + reasoning_tokens + cache_read_tokens + cache_write_tokens`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub reasoning_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub total_tokens: u64,
    /// Provider-reported cost in USD, if available. Zero when the provider
    /// does not report cost.
    #[serde(default)]
    pub cost_usd: f64,
}

/// Stable output contract for delegated execution.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    /// Token usage aggregated across all steps, when available.
    #[serde(default)]
    pub usage: Option<TokenUsage>,
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
            usage: None,
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
            usage: None,
            error: Some(message),
        }
    }
}

/// Compact, durable record of one completed delegation.
///
/// The sandbox a delegation runs in (`opencode-data`, `opencode-state`,
/// `opencode-cache`) is discarded once the run succeeds, and the raw stdout
/// JSONL is pruned on a schedule. Neither can be the source of truth for
/// `locus delegate usage`, which aggregates historical token spend. This
/// manifest is: it is written next to the artifacts before anything is
/// deleted, and it is small enough to keep indefinitely.
///
/// Written as `manifest.json` in the delegation's artifact directory.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DelegationManifest {
    /// Schema version for the manifest file itself.
    pub schema_version: u32,
    /// Unique request identifier — matches the artifact directory name.
    pub id: String,
    /// Backend that executed the task.
    pub backend: DelegationBackend,
    /// Broad delegated task category.
    pub task_kind: DelegationTaskKind,
    /// Provider/model identifier used by the backend.
    pub model: String,
    /// Completion status.
    pub status: DelegationStatus,
    /// Unix epoch seconds at which the run completed.
    pub completed_at: u64,
    /// Execution duration in milliseconds.
    pub duration_ms: u64,
    /// Token usage aggregated across all steps, when the backend reported it.
    #[serde(default)]
    pub usage: Option<TokenUsage>,
    /// Whether the per-run OpenCode sandbox directories were discarded.
    #[serde(default)]
    pub sandbox_discarded: bool,
    /// Structured error message for failures.
    #[serde(default)]
    pub error: Option<String>,
}

impl DelegationManifest {
    /// Current manifest schema version.
    pub const CURRENT_SCHEMA_VERSION: u32 = 1;

    /// File name the manifest is written under, inside the artifact directory.
    pub const FILE_NAME: &'static str = "manifest.json";

    /// Build a manifest from a request and its result.
    pub fn from_result(
        request: &DelegationRequest,
        result: &DelegationResult,
        completed_at: u64,
    ) -> Self {
        Self {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            id: result.id.clone(),
            backend: result.backend.clone(),
            task_kind: request.task_kind.clone(),
            model: result.model.clone(),
            status: result.status.clone(),
            completed_at,
            duration_ms: result.duration_ms,
            usage: result.usage.clone(),
            sandbox_discarded: false,
            error: result.error.clone(),
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
