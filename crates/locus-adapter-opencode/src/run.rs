//! OpenCode command runner for delegated Locus tasks.

use std::fs;
use std::io;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Seconds before the hard timeout at which the parent sends SIGTERM (Unix)
/// to give the agent a chance to wrap up and summarize.
const TIMEOUT_GRACE_PERIOD_SECONDS: u64 = 120;

use locus_core::{
    DelegationMode, DelegationRequest, DelegationResult, DelegationStatus, ExecutionMode,
    LocusError, Platform,
};

/// Command program, arguments, and environment overrides that will invoke OpenCode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenCodeCommandSpec {
    /// Executable name or path.
    pub program: String,
    /// Arguments passed to the executable.
    pub args: Vec<String>,
    /// Environment variables to set on the spawned process.
    ///
    /// Always includes `XDG_DATA_HOME` pointing at a per-delegation data dir
    /// so parallel delegations don't contend on OpenCode's SQLite WAL.
    /// For `ExecutionMode::Native` requests, also includes `XDG_CONFIG_HOME`
    /// pointing at `~/.locus/opencode-native-xdg`, isolating the spawned
    /// OpenCode session from the global Locus install at `~/.config/opencode/`.
    pub envs: Vec<(String, String)>,
}

/// Per-invocation OpenCode data directory under the request's artifact dir.
///
/// OpenCode opens a single SQLite database at `$XDG_DATA_HOME/opencode/opencode.db`.
/// Pointing each delegation at its own `XDG_DATA_HOME` prevents WAL contention
/// when delegations run in parallel.
pub fn opencode_data_dir(request: &DelegationRequest) -> PathBuf {
    request.artifact_dir.join("opencode-data")
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

    if request.execution_mode == ExecutionMode::Native {
        // Skip plugin loading for native sessions — we want maximum isolation
        // from the user's global OpenCode customisations.
        args.push("--pure".to_string());
    }

    args.push(build_delegated_prompt(request));
    args
}

/// Build the env overrides for a delegated request.
///
/// Always sets `XDG_DATA_HOME` to a per-delegation data dir so parallel
/// delegations don't contend on OpenCode's SQLite WAL. Native execution
/// mode additionally redirects `XDG_CONFIG_HOME` to the Locus-managed
/// native config dir so the spawned OpenCode session does not load the
/// algorithmic AGENTS.md or `instructions:` array from `~/.config/opencode/`.
/// Algorithmic mode inherits the parent's config unmodified.
pub fn build_opencode_envs(request: &DelegationRequest) -> Vec<(String, String)> {
    let mut envs = vec![(
        "XDG_DATA_HOME".to_string(),
        opencode_data_dir(request).display().to_string(),
    )];

    if request.execution_mode == ExecutionMode::Native {
        if let Some(home) = dirs::home_dir() {
            let xdg = home.join(".locus").join("opencode-native-xdg");
            envs.push(("XDG_CONFIG_HOME".to_string(), xdg.display().to_string()));
        }
    }

    envs
}

/// Build the command spec using a custom executable path.
pub fn build_opencode_command_with_bin(
    request: &DelegationRequest,
    opencode_bin: impl Into<String>,
) -> OpenCodeCommandSpec {
    OpenCodeCommandSpec {
        program: opencode_bin.into(),
        args: build_opencode_args(request),
        envs: build_opencode_envs(request),
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

    let data_dir = opencode_data_dir(request);
    fs::create_dir_all(&data_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create OpenCode data directory: {}", e),
        path: data_dir.clone(),
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
                let parsed = parse::extract_final_answer(&stdout).map(|answer| {
                    let sections = parse::extract_sections(&answer);
                    (answer, sections)
                });
                let summary = match &parsed {
                    Some((answer, sections)) => sections
                        .summary
                        .clone()
                        .unwrap_or_else(|| answer.trim().to_string()),
                    None => format_artifact_summary(
                        "OpenCode completed successfully",
                        raw_output_path.as_ref(),
                    ),
                };
                let mut result = DelegationResult::success(request, summary, duration_ms);
                if let Some((_, sections)) = parsed {
                    result.findings = sections.findings;
                    result.evidence = sections.evidence;
                    result.risks = sections.risks;
                    result.files_referenced = sections.files_referenced;
                }
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
            let partial_summary = summarize_timeout(&stdout, raw_output_path.as_ref());
            let mut result = DelegationResult::failure(
                request,
                DelegationStatus::TimedOut,
                format!(
                    "OpenCode delegation timed out after {} seconds. {}",
                    request.timeout_seconds, partial_summary
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
        "Locus delegated task. Mode: read_only. Backend: {}. Task kind: {}.\n\
         TIME BUDGET: {} seconds total.\n\
         IMPORTANT: Monitor your elapsed time. If you are within {} minutes of the time limit, STOP your current work immediately, summarize what you have found or accomplished so far, and return your results. Do not let the task time out silently — always provide a summary of progress.\n\n\
         Do not edit files, write files, delete files, commit changes, or mutate persistent project state. Return a compact final answer with summary, findings, evidence, risks, and files referenced.\n\nTask:\n{}",
        request.backend.as_str(),
        request.task_kind.as_str(),
        request.timeout_seconds,
        TIMEOUT_GRACE_PERIOD_SECONDS / 60,
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
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in &spec.envs {
        command.env(key, value);
    }
    let mut child = command.spawn()?;

    // Drain stdout/stderr in background threads. Without this the child
    // blocks the moment its stdout pipe fills (default 64 KiB on macOS
    // and Linux). For opencode delegations any single tool result over
    // ~50 KiB — e.g. reading one large source file — wedges the session
    // mid-stream because the orchestrator only reads stdout *after* the
    // child exits via `wait_with_output`.
    let mut child_stdout = child.stdout.take().expect("stdout was piped");
    let mut child_stderr = child.stderr.take().expect("stderr was piped");
    let stdout_thread = thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = child_stdout.read_to_end(&mut buf);
        buf
    });
    let stderr_thread = thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = child_stderr.read_to_end(&mut buf);
        buf
    });

    let start = Instant::now();
    let grace_period = Duration::from_secs(TIMEOUT_GRACE_PERIOD_SECONDS);
    // Soft deadline is when we ask the process politely to finish (SIGTERM on Unix).
    // Hard deadline is when we forcefully terminate (SIGKILL).
    let soft_timeout = timeout.saturating_sub(grace_period);
    let mut soft_termination_sent = false;

    let exit_code: Option<i32>;
    let timed_out: bool;
    loop {
        match child.try_wait()? {
            Some(status) => {
                exit_code = status.code();
                timed_out = false;
                break;
            }
            None => {
                let elapsed = start.elapsed();

                // Send soft termination signal once when we hit the soft timeout.
                if !soft_termination_sent && elapsed >= soft_timeout && soft_timeout > Duration::ZERO {
                    soft_termination_sent = true;
                    #[cfg(unix)]
                    {
                        // Try SIGTERM first to give the agent a chance to wrap up.
                        let pid = child.id() as i32;
                        unsafe {
                            let _ = libc::kill(pid, libc::SIGTERM);
                        }
                    }
                    // On non-Unix we fall through to the hard kill below at the full timeout.
                }

                if elapsed >= timeout {
                    let _ = child.kill();
                    let _ = child.wait();
                    exit_code = None;
                    timed_out = true;
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }

    // Child has exited; pipes are now closed; reader threads will return.
    let stdout = stdout_thread.join().unwrap_or_default();
    let stderr = stderr_thread.join().unwrap_or_default();

    if timed_out {
        Ok(TimedOutput::TimedOut { stdout, stderr })
    } else {
        Ok(TimedOutput::Completed {
            stdout,
            stderr,
            code: exit_code,
        })
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

fn summarize_timeout(stdout: &[u8], raw_output_path: Option<&PathBuf>) -> String {
    let text = String::from_utf8_lossy(stdout).trim().to_string();
    if text.is_empty() {
        return format_artifact_summary(
            "Partial output may be available",
            raw_output_path,
        );
    }
    let compact = compact_text(&text, 1200);
    format!(
        "Partial output excerpt: {}",
        compact
    )
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

pub(crate) mod parse {
    //! JSONL event parsing for OpenCode `--format json` output.

    use serde_json::Value;

    /// Parsed markdown sections from a delegated final answer.
    #[derive(Debug, Default, Clone, PartialEq, Eq)]
    pub struct ParsedSections {
        pub summary: Option<String>,
        pub findings: Vec<String>,
        pub evidence: Vec<String>,
        pub risks: Vec<String>,
        pub files_referenced: Vec<String>,
    }

    /// Pull the model's final answer text from an OpenCode JSONL stdout stream.
    ///
    /// Prefers the last text event marked `phase = "final_answer"` and falls
    /// back to the last text event of any phase. Returns None when no text
    /// events are present.
    pub fn extract_final_answer(stdout: &[u8]) -> Option<String> {
        let raw = std::str::from_utf8(stdout).ok()?;
        let mut last_text: Option<String> = None;
        let mut last_final_answer: Option<String> = None;

        for line in raw.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(trimmed) {
                Ok(v) => v,
                Err(_) => continue,
            };
            if value.get("type").and_then(Value::as_str) != Some("text") {
                continue;
            }
            let part = match value.get("part") {
                Some(p) => p,
                None => continue,
            };
            let text = match part.get("text").and_then(Value::as_str) {
                Some(t) if !t.trim().is_empty() => t.to_string(),
                _ => continue,
            };
            last_text = Some(text.clone());
            let phase = part
                .pointer("/metadata/openai/phase")
                .and_then(Value::as_str);
            if phase == Some("final_answer") {
                last_final_answer = Some(text);
            }
        }

        last_final_answer.or(last_text)
    }

    /// Split a markdown final answer into known structured sections.
    ///
    /// Recognises `**Summary**`, `**Findings**`, `**Evidence**`, `**Risks**`,
    /// and `**Files Referenced**` headers. Bullet lines (`- item`) under each
    /// header populate the matching vector; non-bullet text under `**Summary**`
    /// becomes the summary string. Content outside known sections is ignored.
    pub fn extract_sections(answer: &str) -> ParsedSections {
        let mut sections = ParsedSections::default();
        let mut current: Option<Section> = None;
        let mut summary_lines: Vec<String> = Vec::new();

        for raw_line in answer.lines() {
            let line = raw_line.trim();
            if let Some(section) = match_header(line) {
                if let Some(Section::Summary) = current {
                    if !summary_lines.is_empty() {
                        sections.summary = Some(summary_lines.join("\n").trim().to_string());
                        summary_lines.clear();
                    }
                }
                current = Some(section);
                continue;
            }
            let Some(section) = current else { continue };
            match section {
                Section::Summary => {
                    if !line.is_empty() {
                        summary_lines.push(line.to_string());
                    }
                }
                Section::Findings => push_bullet(line, &mut sections.findings),
                Section::Evidence => push_bullet(line, &mut sections.evidence),
                Section::Risks => push_bullet(line, &mut sections.risks),
                Section::FilesReferenced => push_bullet(line, &mut sections.files_referenced),
            }
        }
        if let Some(Section::Summary) = current {
            if !summary_lines.is_empty() && sections.summary.is_none() {
                sections.summary = Some(summary_lines.join("\n").trim().to_string());
            }
        }
        sections
    }

    #[derive(Copy, Clone)]
    enum Section {
        Summary,
        Findings,
        Evidence,
        Risks,
        FilesReferenced,
    }

    fn match_header(line: &str) -> Option<Section> {
        match line {
            "**Summary**" => Some(Section::Summary),
            "**Findings**" => Some(Section::Findings),
            "**Evidence**" => Some(Section::Evidence),
            "**Risks**" => Some(Section::Risks),
            "**Files Referenced**" => Some(Section::FilesReferenced),
            _ => None,
        }
    }

    fn push_bullet(line: &str, dest: &mut Vec<String>) {
        if let Some(rest) = line.strip_prefix("- ") {
            let item = strip_wrapping_backticks(rest.trim());
            if !item.is_empty() {
                dest.push(item.to_string());
            }
        }
    }

    fn strip_wrapping_backticks(item: &str) -> &str {
        item.strip_prefix('`')
            .and_then(|s| s.strip_suffix('`'))
            .filter(|s| !s.contains('`'))
            .unwrap_or(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_core::{
        DelegationBackend, DelegationMode, DelegationRequest, DelegationTaskKind, ExecutionMode,
    };
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
            execution_mode: ExecutionMode::Native,
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
    fn native_mode_spec_has_pure_arg_and_xdg_env() {
        let mut request = sample_request();
        request.execution_mode = ExecutionMode::Native;
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        assert!(
            spec.args.iter().any(|a| a == "--pure"),
            "native mode must pass --pure to skip plugin loading"
        );
        let xdg = spec
            .envs
            .iter()
            .find(|(k, _)| k == "XDG_CONFIG_HOME")
            .expect("native mode must set XDG_CONFIG_HOME");
        assert!(
            xdg.1.ends_with("opencode-native-xdg"),
            "XDG_CONFIG_HOME should point at the Locus-managed native config dir, got {}",
            xdg.1
        );
    }

    #[test]
    fn algorithmic_mode_spec_has_no_pure_and_no_xdg_config_override() {
        let mut request = sample_request();
        request.execution_mode = ExecutionMode::Algorithmic;
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        assert!(
            !spec.args.iter().any(|a| a == "--pure"),
            "algorithmic mode must NOT pass --pure"
        );
        assert!(
            !spec.envs.iter().any(|(k, _)| k == "XDG_CONFIG_HOME"),
            "algorithmic mode must inherit OpenCode config from the global install, got {:?}",
            spec.envs
        );
    }

    /// Regression for the 64 KiB stdout pipe deadlock. Pre-fix runs of
    /// `run_command_with_timeout` only drained the child's stdout via
    /// `child.wait_with_output()` *after* the child had exited, so any
    /// child that wrote more than the pipe-buffer size before exiting
    /// blocked forever and our 1200 s timeout was needed to recover (with
    /// truncated, useless output). This test spawns a child that writes
    /// 200 000 NUL bytes — well past 64 KiB — and asserts we capture all
    /// of them and report a clean non-timeout exit.
    #[test]
    fn large_stdout_does_not_deadlock() {
        let spec = OpenCodeCommandSpec {
            program: "head".into(),
            args: vec!["-c".into(), "200000".into(), "/dev/zero".into()],
            envs: Vec::new(),
        };
        let outcome = run_command_with_timeout(&spec, Duration::from_secs(10))
            .expect("spawn ok");
        match outcome {
            TimedOutput::Completed {
                stdout,
                stderr: _,
                code,
            } => {
                assert_eq!(stdout.len(), 200_000, "expected full pipe drain");
                assert_eq!(code, Some(0));
            }
            TimedOutput::TimedOut { .. } => {
                panic!("child timed out — pipe deadlock is back")
            }
        }
    }

    #[test]
    fn delegated_prompt_includes_timeout_and_wrap_up_instructions() {
        let request = sample_request();
        let prompt = build_delegated_prompt(&request);

        assert!(prompt.contains(&format!("TIME BUDGET: {} seconds total", request.timeout_seconds)));
        assert!(prompt.contains("within 2 minutes of the time limit"));
        assert!(prompt.contains("STOP your current work immediately"));
        assert!(prompt.contains("summarize what you have found"));
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
    fn command_spec_isolates_xdg_data_home_per_request() {
        let request = sample_request();
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        let xdg = spec
            .envs
            .iter()
            .find(|(k, _)| k == "XDG_DATA_HOME")
            .map(|(_, v)| v.clone())
            .expect("spec envs should set XDG_DATA_HOME");

        let expected = request
            .artifact_dir
            .join("opencode-data")
            .display()
            .to_string();
        assert_eq!(xdg, expected);
    }

    #[test]
    fn run_creates_per_invocation_data_dir() {
        let request = sample_request();
        let _ = run_delegation_with_bin(&request, "true").unwrap();

        let data_dir = request.artifact_dir.join("opencode-data");
        assert!(
            data_dir.is_dir(),
            "expected per-invocation OpenCode data dir at {}",
            data_dir.display()
        );
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

    const SMOKE_FIXTURE: &str =
        include_str!("../tests/fixtures/opencode_final_answer.jsonl");

    #[test]
    fn parse_extracts_final_answer_from_smoke_fixture() {
        let answer = parse::extract_final_answer(SMOKE_FIXTURE.as_bytes())
            .expect("smoke fixture should yield a final answer");

        assert!(answer.contains("**Summary**"));
        assert!(answer.contains("**Findings**"));
        assert!(answer.contains("locus-cli"));

        let sections = parse::extract_sections(&answer);

        assert!(sections
            .summary
            .as_deref()
            .unwrap()
            .contains("six top-level crates"));
        assert!(sections.findings.iter().any(|f| f.contains("locus-cli")));
        assert!(sections.findings.iter().any(|f| f.contains("locus-core")));
        assert!(sections
            .findings
            .iter()
            .any(|f| f.contains("locus-adapter-opencode")));
        assert!(sections.evidence.iter().any(|e| e.contains("Cargo.toml")));
        assert!(!sections.risks.is_empty());
        assert!(sections
            .files_referenced
            .iter()
            .any(|f| f == "Cargo.toml"));
        assert!(sections
            .files_referenced
            .iter()
            .any(|f| f.contains("locus-cli/Cargo.toml")));
    }

    #[test]
    fn parse_falls_back_to_last_text_when_no_final_answer_phase() {
        let stdout = concat!(
            "{\"type\":\"text\",\"part\":{\"text\":\"first\"}}\n",
            "{\"type\":\"text\",\"part\":{\"text\":\"second\"}}\n",
        );
        let answer = parse::extract_final_answer(stdout.as_bytes()).unwrap();
        assert_eq!(answer, "second");
    }

    #[test]
    fn parse_returns_none_for_empty_stdout() {
        assert!(parse::extract_final_answer(b"").is_none());
        assert!(parse::extract_final_answer(b"\n\n").is_none());
    }

    #[test]
    fn parse_skips_malformed_lines() {
        let stdout = concat!(
            "not json at all\n",
            "{\"type\":\"text\",\"part\":{\"text\":\"good\"}}\n",
            "{not closed\n",
        );
        let answer = parse::extract_final_answer(stdout.as_bytes()).unwrap();
        assert_eq!(answer, "good");
    }

    #[test]
    fn parse_returns_whole_answer_when_no_sections_present() {
        let answer = "Just a free-form response without any section headers.";
        let sections = parse::extract_sections(answer);
        assert!(sections.summary.is_none());
        assert!(sections.findings.is_empty());
    }

    #[test]
    fn parse_extracts_each_named_section() {
        let answer = concat!(
            "preamble line\n",
            "**Summary**\n",
            "All went well.\n",
            "\n",
            "**Findings**\n",
            "- finding one\n",
            "- finding two\n",
            "\n",
            "**Evidence**\n",
            "- evidence one\n",
            "\n",
            "**Risks**\n",
            "- risk one\n",
            "\n",
            "**Files Referenced**\n",
            "- src/lib.rs\n",
            "- src/main.rs\n",
        );
        let sections = parse::extract_sections(answer);
        assert_eq!(sections.summary.as_deref(), Some("All went well."));
        assert_eq!(sections.findings, vec!["finding one", "finding two"]);
        assert_eq!(sections.evidence, vec!["evidence one"]);
        assert_eq!(sections.risks, vec!["risk one"]);
        assert_eq!(
            sections.files_referenced,
            vec!["src/lib.rs", "src/main.rs"]
        );
    }
}
