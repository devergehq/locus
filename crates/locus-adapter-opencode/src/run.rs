//! OpenCode command runner for delegated Locus tasks.

use std::fs;
use std::io;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use locus_core::{
    DelegationMode, DelegationRequest, DelegationResult, DelegationStatus, LocusError, Platform,
};

/// Command program and arguments that will invoke OpenCode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeCommandSpec {
    /// Executable name or path.
    pub program: String,
    /// Arguments passed to the executable.
    pub args: Vec<String>,
}

/// Build deterministic `opencode run` arguments for a delegated request.
pub fn build_opencode_args(request: &DelegationRequest) -> Vec<String> {
    let mut args = vec![
        "run".to_string(),
        "--model".to_string(),
        request.model.clone(),
    ];

    if let Some(agent) = &request.agent {
        args.push("--agent".to_string());
        args.push(agent.clone());
    }

    args.push("--format".to_string());
    args.push("json".to_string());
    args.push("--dir".to_string());
    args.push(request.workspace_dir.display().to_string());

    if let Some(variant) = &request.variant {
        args.push("--variant".to_string());
        args.push(variant.clone());
    }

    for file in &request.context_files {
        args.push("--file".to_string());
        args.push(file.display().to_string());
    }

    args.push(build_delegated_prompt(request));
    args
}

/// Build the command spec using a custom executable path.
pub fn build_opencode_command_with_bin(
    request: &DelegationRequest,
    opencode_bin: impl Into<String>,
) -> OpenCodeCommandSpec {
    OpenCodeCommandSpec {
        program: opencode_bin.into(),
        args: build_opencode_args(request),
    }
}

/// Build the command spec using the default OpenCode executable.
pub fn build_opencode_command(request: &DelegationRequest) -> OpenCodeCommandSpec {
    build_opencode_command_with_bin(request, Platform::OpenCode.cli_command())
}

/// Execute a delegated request through OpenCode.
pub fn run_delegation(request: &DelegationRequest) -> Result<DelegationResult, LocusError> {
    run_delegation_with_bin(request, Platform::OpenCode.cli_command())
}

/// Execute a delegated request through a custom OpenCode executable.
pub fn run_delegation_with_bin(
    request: &DelegationRequest,
    opencode_bin: impl Into<String>,
) -> Result<DelegationResult, LocusError> {
    if request.mode != DelegationMode::ReadOnly {
        return Ok(DelegationResult::failure(
            request,
            DelegationStatus::Failure,
            "Only read_only delegation is currently supported".into(),
            0,
        ));
    }

    fs::create_dir_all(&request.artifact_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create delegation artifact directory: {}", e),
        path: request.artifact_dir.clone(),
    })?;

    let spec = build_opencode_command_with_bin(request, opencode_bin);
    let start = Instant::now();
    let output = run_command_with_timeout(&spec, Duration::from_secs(request.timeout_seconds));
    let duration_ms = elapsed_ms(start.elapsed());

    match output {
        Ok(TimedOutput::Completed {
            stdout,
            stderr,
            code,
        }) => {
            let mut artifacts = write_artifacts(request, &stdout, &stderr)?;
            let raw_output_path = artifacts.first().cloned();

            if code == Some(0) {
                let mut result = DelegationResult::success(
                    request,
                    summarize_success(&stdout, raw_output_path.as_ref()),
                    duration_ms,
                );
                result.artifacts.append(&mut artifacts);
                result.raw_output_path = raw_output_path;
                Ok(result)
            } else {
                let message = summarize_failure(code, &stderr, &stdout);
                let mut result = DelegationResult::failure(
                    request,
                    DelegationStatus::Failure,
                    message,
                    duration_ms,
                );
                result.artifacts.append(&mut artifacts);
                result.raw_output_path = raw_output_path;
                Ok(result)
            }
        }
        Ok(TimedOutput::TimedOut { stdout, stderr }) => {
            let mut artifacts = write_artifacts(request, &stdout, &stderr)?;
            let raw_output_path = artifacts.first().cloned();
            let mut result = DelegationResult::failure(
                request,
                DelegationStatus::TimedOut,
                format!(
                    "OpenCode delegation timed out after {} seconds",
                    request.timeout_seconds
                ),
                duration_ms,
            );
            result.artifacts.append(&mut artifacts);
            result.raw_output_path = raw_output_path;
            Ok(result)
        }
        Err(e) => Ok(DelegationResult::failure(
            request,
            DelegationStatus::Failure,
            format!("Failed to run OpenCode: {}", e),
            duration_ms,
        )),
    }
}

fn build_delegated_prompt(request: &DelegationRequest) -> String {
    format!(
        "Locus delegated task. Mode: read_only. Backend: {}. Task kind: {}.\n\nDo not edit files, write files, delete files, commit changes, or mutate persistent project state. Return a compact final answer with summary, findings, evidence, risks, and files referenced.\n\nTask:\n{}",
        request.backend.as_str(),
        request.task_kind.as_str(),
        request.prompt
    )
}

enum TimedOutput {
    Completed {
        stdout: Vec<u8>,
        stderr: Vec<u8>,
        code: Option<i32>,
    },
    TimedOut {
        stdout: Vec<u8>,
        stderr: Vec<u8>,
    },
}

fn run_command_with_timeout(
    spec: &OpenCodeCommandSpec,
    timeout: Duration,
) -> io::Result<TimedOutput> {
    let mut child = Command::new(&spec.program)
        .args(&spec.args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let start = Instant::now();
    loop {
        if child.try_wait()?.is_some() {
            let output = child.wait_with_output()?;
            return Ok(TimedOutput::Completed {
                stdout: output.stdout,
                stderr: output.stderr,
                code: output.status.code(),
            });
        }

        if start.elapsed() >= timeout {
            let _ = child.kill();
            let output = child.wait_with_output()?;
            return Ok(TimedOutput::TimedOut {
                stdout: output.stdout,
                stderr: output.stderr,
            });
        }

        thread::sleep(Duration::from_millis(50));
    }
}

fn write_artifacts(
    request: &DelegationRequest,
    stdout: &[u8],
    stderr: &[u8],
) -> Result<Vec<PathBuf>, LocusError> {
    let stdout_path = request
        .artifact_dir
        .join(format!("{}-opencode-stdout.jsonl", request.id));
    fs::write(&stdout_path, stdout).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write OpenCode stdout artifact: {}", e),
        path: stdout_path.clone(),
    })?;

    let mut artifacts = vec![stdout_path];
    if !stderr.is_empty() {
        let stderr_path = request
            .artifact_dir
            .join(format!("{}-opencode-stderr.log", request.id));
        fs::write(&stderr_path, stderr).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to write OpenCode stderr artifact: {}", e),
            path: stderr_path.clone(),
        })?;
        artifacts.push(stderr_path);
    }

    Ok(artifacts)
}

fn summarize_success(stdout: &[u8], raw_output_path: Option<&PathBuf>) -> String {
    let text = String::from_utf8_lossy(stdout).trim().to_string();
    if text.is_empty() {
        return format_artifact_summary("OpenCode completed successfully", raw_output_path);
    }

    let compact = compact_text(&text, 1200);
    format!(
        "OpenCode completed successfully. Compact output excerpt: {}",
        compact
    )
}

fn summarize_failure(code: Option<i32>, stderr: &[u8], stdout: &[u8]) -> String {
    let stderr_text = String::from_utf8_lossy(stderr).trim().to_string();
    let stdout_text = String::from_utf8_lossy(stdout).trim().to_string();
    let detail = if !stderr_text.is_empty() {
        compact_text(&stderr_text, 1200)
    } else if !stdout_text.is_empty() {
        compact_text(&stdout_text, 1200)
    } else {
        "no output".into()
    };

    format!("OpenCode exited with status {:?}: {}", code, detail)
}

fn format_artifact_summary(prefix: &str, raw_output_path: Option<&PathBuf>) -> String {
    match raw_output_path {
        Some(path) => format!("{}. Raw output: {}", prefix, path.display()),
        None => prefix.to_string(),
    }
}

fn compact_text(text: &str, max_chars: usize) -> String {
    let mut chars = text.chars();
    let compact: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{}...", compact)
    } else {
        compact
    }
}

fn elapsed_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_core::{DelegationBackend, DelegationMode, DelegationRequest, DelegationTaskKind};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn sample_request() -> DelegationRequest {
        DelegationRequest {
            id: unique_id(),
            backend: DelegationBackend::OpenCode,
            task_kind: DelegationTaskKind::Research,
            model: "openai/gpt-5.5".into(),
            agent: Some("research".into()),
            variant: Some("high".into()),
            workspace_dir: PathBuf::from("/tmp/project"),
            prompt: "Research readback patterns".into(),
            context_files: vec![PathBuf::from("/tmp/context.md")],
            mode: DelegationMode::ReadOnly,
            output_schema_version: DelegationRequest::CURRENT_SCHEMA_VERSION,
            artifact_dir: std::env::temp_dir().join(unique_id()),
            timeout_seconds: 5,
        }
    }

    fn unique_id() -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("delegate-test-{}", nanos)
    }

    #[test]
    fn command_builder_uses_deterministic_arguments() {
        let request = sample_request();
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        assert_eq!(spec.program, "opencode-test");
        assert_eq!(spec.args[0], "run");
        assert_eq!(spec.args[1], "--model");
        assert_eq!(spec.args[2], "openai/gpt-5.5");
        assert!(spec.args.windows(2).any(|w| w == ["--agent", "research"]));
        assert!(spec.args.windows(2).any(|w| w == ["--format", "json"]));
        assert!(spec.args.windows(2).any(|w| w == ["--variant", "high"]));
        assert!(spec
            .args
            .windows(2)
            .any(|w| w == ["--file", "/tmp/context.md"]));
        assert!(spec.args.last().unwrap().contains("Mode: read_only"));
    }

    #[test]
    fn successful_run_records_stdout_artifact() {
        let request = sample_request();
        let result = run_delegation_with_bin(&request, "true").unwrap();

        assert_eq!(result.status, DelegationStatus::Success);
        let raw = result.raw_output_path.as_ref().unwrap();
        assert!(raw.exists());
        assert!(raw.ends_with(format!("{}-opencode-stdout.jsonl", request.id)));
        let _ = fs::remove_dir_all(&request.artifact_dir);
    }

    #[test]
    fn nonzero_run_returns_structured_failure() {
        let request = sample_request();
        let result = run_delegation_with_bin(&request, "false").unwrap();

        assert_eq!(result.status, DelegationStatus::Failure);
        assert!(result.error.as_deref().unwrap().contains("OpenCode exited"));
        assert!(result.raw_output_path.as_ref().unwrap().exists());
        let _ = fs::remove_dir_all(&request.artifact_dir);
    }
}
