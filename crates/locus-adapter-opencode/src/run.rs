//! OpenCode command runner for delegated Locus tasks.

use std::fs;
use std::io;
use std::io::Read;
use std::path::{Path, PathBuf};
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
    /// Always includes `XDG_DATA_HOME` and `XDG_STATE_HOME` pointing at
    /// per-delegation directories so parallel delegations don't contend on
    /// OpenCode's SQLite WAL (data) or its `models.dev` catalog lockfile
    /// (state — `$XDG_STATE_HOME/opencode/locks/<sha>.lock`). Without state
    /// isolation, parallel delegations race on the same lockfile and one
    /// of them wedges at startup with no recovery.
    ///
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

/// Per-invocation OpenCode state directory under the request's artifact dir.
///
/// OpenCode writes lockfiles under `$XDG_STATE_HOME/opencode/locks/`. Pointing
/// each delegation at its own `XDG_STATE_HOME` prevents lockfile contention
/// when delegations run in parallel — without this, parallel delegations all
/// attempt to mkdir the same `~/.local/state/opencode/locks/<sha>.lock` path
/// and either receive `EPERM` (under sandbox) or wedge waiting on the lock.
pub fn opencode_state_dir(request: &DelegationRequest) -> PathBuf {
    request.artifact_dir.join("opencode-state")
}

/// Per-invocation OpenCode cache directory under the request's artifact dir.
///
/// OpenCode caches the `models.dev` catalog at `$XDG_CACHE_HOME/opencode/models.json`.
/// Pointing each delegation at its own `XDG_CACHE_HOME` is required under any
/// sandbox that restricts writes outside the delegation tree (Claude Code's
/// default sandbox blocks writes under `~/.cache`). Without this isolation,
/// the cache write fails silently and OpenCode falls back to its tiny bundled
/// model list — which omits recent models like `gpt-5.5`, surfacing as
/// `ProviderModelNotFoundError` despite the model existing in the live catalog.
pub fn opencode_cache_dir(request: &DelegationRequest) -> PathBuf {
    request.artifact_dir.join("opencode-cache")
}

/// Seed the per-delegation cache with the user's existing `models.json` if any.
///
/// OpenCode loads its model catalog on startup but performs the `models.dev`
/// catalog refresh asynchronously, dispatching the user's first request before
/// the refresh completes. With an empty cache that means the model registry is
/// empty when the request fires and any model lookup returns
/// `ProviderModelNotFoundError`. By copying the user's existing
/// `~/.cache/opencode/models.json` into the per-delegation cache before spawn,
/// we ensure the registry is populated synchronously at startup — matching the
/// behaviour observed when the cache was global and pre-populated. Errors are
/// swallowed silently because the fallback (OpenCode's own fetch) should still
/// work for users on systems without an existing cache file.
fn seed_opencode_models_cache(cache_dir: &Path) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let source = home.join(".cache").join("opencode").join("models.json");
    if !source.exists() {
        return;
    }
    let dest_dir = cache_dir.join("opencode");
    if fs::create_dir_all(&dest_dir).is_err() {
        return;
    }
    let _ = fs::copy(&source, dest_dir.join("models.json"));
}

/// Seed the per-delegation data directory with the user's OpenCode credentials.
///
/// `$XDG_DATA_HOME/opencode/auth.json` is OpenCode's credential file —
/// without it the spawned session has no provider auth and cannot dispatch
/// any LLM call. Lacking auth, OpenCode reports `ProviderModelNotFoundError`
/// for the requested model (the provider is filtered out before model
/// lookup). The file is mode 0600 so we preserve those permissions on the
/// copy. Errors are swallowed silently — if auth seeding fails the user
/// will see the same `Model not found` error they would have seen anyway.
fn seed_opencode_auth(data_dir: &Path) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let source = home
        .join(".local")
        .join("share")
        .join("opencode")
        .join("auth.json");
    if !source.exists() {
        return;
    }
    let dest_dir = data_dir.join("opencode");
    if fs::create_dir_all(&dest_dir).is_err() {
        return;
    }
    let dest = dest_dir.join("auth.json");
    if fs::copy(&source, &dest).is_err() {
        return;
    }
    // auth.json contains credentials — restrict to owner read/write.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if let Ok(metadata) = fs::metadata(&dest) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o600);
            let _ = fs::set_permissions(&dest, perms);
        }
    }
}

/// Seed the per-delegation state with the user's runtime model registry.
///
/// `$XDG_STATE_HOME/opencode/model.json` is OpenCode's runtime model registry —
/// it's the file that records which models the user has used recently and
/// which variant (e.g. `xhigh`) to dispatch them with. Without this file
/// OpenCode treats any non-bundled model as unknown and emits
/// `ProviderModelNotFoundError` even when the catalog at
/// `$XDG_CACHE_HOME/opencode/models.json` lists the model. Lock subdirectories
/// under `state/opencode/locks/` are deliberately NOT seeded — those must
/// remain per-delegation for parallelism. We only copy the small top-level
/// preference files that drive model resolution.
fn seed_opencode_user_state(state_dir: &Path) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let dest_dir = state_dir.join("opencode");
    if fs::create_dir_all(&dest_dir).is_err() {
        return;
    }
    for filename in ["model.json", "kv.json"] {
        let source = home.join(".local").join("state").join("opencode").join(filename);
        if source.exists() {
            let _ = fs::copy(&source, dest_dir.join(filename));
        }
    }
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
/// Always sets `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` to
/// per-delegation dirs so the entire OpenCode footprint lives inside the
/// delegation's artifact tree. This prevents parallel delegations from
/// contending on OpenCode's SQLite WAL (data), its `models.dev` lockfile
/// (state), or its `models.dev` catalog cache (cache); it also keeps
/// OpenCode functional under sandboxes that restrict writes under `~/.cache`,
/// `~/.local/state`, or `~/.local/share`.
///
/// Native execution mode additionally redirects `XDG_CONFIG_HOME` to the
/// Locus-managed native config dir so the spawned OpenCode session does not
/// load the algorithmic AGENTS.md or `instructions:` array from
/// `~/.config/opencode/`. Algorithmic mode inherits the parent's config
/// unmodified.
pub fn build_opencode_envs(request: &DelegationRequest) -> Vec<(String, String)> {
    let mut envs = vec![
        (
            "XDG_DATA_HOME".to_string(),
            opencode_data_dir(request).display().to_string(),
        ),
        (
            "XDG_STATE_HOME".to_string(),
            opencode_state_dir(request).display().to_string(),
        ),
        (
            "XDG_CACHE_HOME".to_string(),
            opencode_cache_dir(request).display().to_string(),
        ),
    ];

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
    seed_opencode_auth(&data_dir);

    let state_dir = opencode_state_dir(request);
    fs::create_dir_all(&state_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create OpenCode state directory: {}", e),
        path: state_dir.clone(),
    })?;

    let cache_dir = opencode_cache_dir(request);
    fs::create_dir_all(&cache_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create OpenCode cache directory: {}", e),
        path: cache_dir.clone(),
    })?;
    seed_opencode_models_cache(&cache_dir);
    seed_opencode_user_state(&state_dir);

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
                // OpenCode sometimes exits 0 even when the only stdout event
                // was a fatal error (e.g. ProviderModelNotFoundError). Don't
                // claim success when the JSONL stream contains an error event
                // — surface the error message so the caller can act on it.
                if let Some(error_message) = parse::extract_error_message(&stdout) {
                    let mut result = DelegationResult::failure(
                        request,
                        DelegationStatus::Failure,
                        format!("OpenCode reported an error: {}", error_message),
                        duration_ms,
                    );
                    result.artifacts.append(&mut artifacts);
                    result.raw_output_path = raw_output_path;
                    return Ok(result);
                }

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
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (key, value) in &spec.envs {
        command.env(key, value);
    }
    // Stdin is explicitly /dev/null because OpenCode's startup blocks reading
    // from stdin when the parent has no TTY (e.g. when locus is itself
    // backgrounded). Inheriting stdin from a half-open unix socket wedges the
    // child indefinitely at the json-migration step with no error logged.
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

    /// Pull the first error message from an OpenCode JSONL stdout stream.
    ///
    /// Returns the human-readable message of the first event with
    /// `type = "error"`, preferring `error.data.message` and falling back to
    /// `error.name`. Returns None when no error events are present. Used to
    /// detect fatal errors that don't propagate to OpenCode's exit code (e.g.
    /// `ProviderModelNotFoundError` exits 0 but emits only an error event).
    pub fn extract_error_message(stdout: &[u8]) -> Option<String> {
        let raw = std::str::from_utf8(stdout).ok()?;
        for line in raw.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let value: Value = match serde_json::from_str(trimmed) {
                Ok(v) => v,
                Err(_) => continue,
            };
            if value.get("type").and_then(Value::as_str) != Some("error") {
                continue;
            }
            let error = match value.get("error") {
                Some(e) => e,
                None => continue,
            };
            if let Some(message) = error
                .pointer("/data/message")
                .and_then(Value::as_str)
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
            {
                return Some(message.to_string());
            }
            if let Some(name) = error
                .get("name")
                .and_then(Value::as_str)
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
            {
                return Some(name.to_string());
            }
        }
        None
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
    fn command_spec_isolates_xdg_state_home_per_request() {
        let request = sample_request();
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        let xdg = spec
            .envs
            .iter()
            .find(|(k, _)| k == "XDG_STATE_HOME")
            .map(|(_, v)| v.clone())
            .expect("spec envs should set XDG_STATE_HOME");

        let expected = request
            .artifact_dir
            .join("opencode-state")
            .display()
            .to_string();
        assert_eq!(xdg, expected);
    }

    #[test]
    fn run_creates_per_invocation_state_dir() {
        let request = sample_request();
        let _ = run_delegation_with_bin(&request, "true").unwrap();

        let state_dir = request.artifact_dir.join("opencode-state");
        assert!(
            state_dir.is_dir(),
            "expected per-invocation OpenCode state dir at {}",
            state_dir.display()
        );
        let _ = fs::remove_dir_all(&request.artifact_dir);
    }

    #[test]
    fn command_spec_isolates_xdg_cache_home_per_request() {
        let request = sample_request();
        let spec = build_opencode_command_with_bin(&request, "opencode-test");

        let xdg = spec
            .envs
            .iter()
            .find(|(k, _)| k == "XDG_CACHE_HOME")
            .map(|(_, v)| v.clone())
            .expect("spec envs should set XDG_CACHE_HOME");

        let expected = request
            .artifact_dir
            .join("opencode-cache")
            .display()
            .to_string();
        assert_eq!(xdg, expected);
    }

    #[test]
    fn run_creates_per_invocation_cache_dir() {
        let request = sample_request();
        let _ = run_delegation_with_bin(&request, "true").unwrap();

        let cache_dir = request.artifact_dir.join("opencode-cache");
        assert!(
            cache_dir.is_dir(),
            "expected per-invocation OpenCode cache dir at {}",
            cache_dir.display()
        );
        let _ = fs::remove_dir_all(&request.artifact_dir);
    }

    #[test]
    fn parse_extracts_error_message_with_data_message() {
        let stdout = concat!(
            r#"{"type":"error","timestamp":1,"sessionID":"s","error":{"name":"UnknownError","data":{"message":"Model not found: openai/gpt-5.5."}}}"#,
            "\n",
        );
        let msg = parse::extract_error_message(stdout.as_bytes()).unwrap();
        assert_eq!(msg, "Model not found: openai/gpt-5.5.");
    }

    #[test]
    fn parse_extracts_error_message_falls_back_to_name() {
        let stdout = r#"{"type":"error","error":{"name":"UnknownError"}}"#;
        let msg = parse::extract_error_message(stdout.as_bytes()).unwrap();
        assert_eq!(msg, "UnknownError");
    }

    #[test]
    fn parse_returns_none_when_no_error_event() {
        let stdout = concat!(
            r#"{"type":"text","part":{"text":"all good"}}"#,
            "\n",
        );
        assert!(parse::extract_error_message(stdout.as_bytes()).is_none());
    }

    #[test]
    fn exit_zero_with_error_event_is_reported_as_failure() {
        // Simulate the ProviderModelNotFoundError pattern: opencode exits 0
        // but the only stdout is an error envelope. We must report Failure,
        // not Success.
        use std::io::Write;
        let request = sample_request();
        let script_path = request.artifact_dir.join("fake-opencode.sh");
        fs::create_dir_all(&request.artifact_dir).unwrap();
        let mut script = fs::File::create(&script_path).unwrap();
        write!(
            script,
            "#!/bin/sh\ncat <<'EOF'\n{}\nEOF\nexit 0\n",
            r#"{"type":"error","timestamp":1,"sessionID":"s","error":{"name":"X","data":{"message":"Model not found: openai/gpt-5.5."}}}"#,
        )
        .unwrap();
        drop(script);
        let _ = std::process::Command::new("chmod")
            .args(["+x", script_path.to_str().unwrap()])
            .output();

        let result = run_delegation_with_bin(&request, script_path.to_str().unwrap()).unwrap();

        assert_eq!(
            result.status,
            DelegationStatus::Failure,
            "exit-0 with error event must be Failure, got {:?}",
            result.status
        );
        assert!(
            result
                .error
                .as_deref()
                .unwrap_or("")
                .contains("Model not found: openai/gpt-5.5"),
            "error message should surface, got {:?}",
            result.error
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
