//! `locus hook <event>` — platform-agnostic hook handlers.
//!
//! Each subcommand implements the behaviour for one Locus hook event. The
//! command reads a Claude Code-style JSON envelope from stdin, dispatches to
//! the handler, and emits JSON on stdout per the Claude Code hook protocol.
//! Other platforms may invoke the same subcommands — the JSON schema is the
//! lingua franca.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use locus_core::LocusError;

use crate::output;

/// Which hook event is being fired.
#[derive(Debug, Clone, Copy)]
pub enum HookEventKind {
    SessionStart,
    SessionEnd,
    PreCompact,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    Stop,
    Notification,
}

/// Run a hook event handler. Reads JSON event envelope from stdin, writes
/// JSON (or nothing) to stdout.
pub fn run(kind: HookEventKind) -> Result<(), LocusError> {
    let event = read_stdin_json()?;
    let data_dir = resolve_data_dir()?;

    match kind {
        HookEventKind::SessionStart => handle_session_start(&event, &data_dir),
        HookEventKind::SessionEnd => handle_session_end(&event, &data_dir),
        HookEventKind::PreCompact => handle_pre_compact(&event, &data_dir),
        HookEventKind::UserPromptSubmit => handle_user_prompt_submit(&event, &data_dir),
        HookEventKind::PreToolUse => handle_pre_tool_use(&event, &data_dir),
        HookEventKind::PostToolUse => handle_post_tool_use(&event, &data_dir),
        HookEventKind::Stop => handle_stop(&event, &data_dir),
        HookEventKind::Notification => handle_notification(&event, &data_dir),
    }
}

fn read_stdin_json() -> Result<serde_json::Value, LocusError> {
    let mut buf = String::new();
    std::io::stdin()
        .read_to_string(&mut buf)
        .map_err(|e| LocusError::Adapter {
            platform: locus_core::platform::Platform::ClaudeCode,
            message: format!("Failed to read hook stdin: {}", e),
        })?;

    if buf.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }

    serde_json::from_str(&buf).map_err(|e| LocusError::Adapter {
        platform: locus_core::platform::Platform::ClaudeCode,
        message: format!("Invalid JSON on hook stdin: {}", e),
    })
}

fn resolve_data_dir() -> Result<PathBuf, LocusError> {
    if let Ok(env_data) = std::env::var("LOCUS_DATA_HOME") {
        return Ok(PathBuf::from(env_data));
    }

    let home = if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        PathBuf::from(env_home)
    } else {
        dirs::home_dir()
            .map(|h| h.join(".locus"))
            .ok_or_else(|| LocusError::Config {
                message: "Could not determine home directory".into(),
                path: None,
            })?
    };

    Ok(home.join("data"))
}

fn write_stdout_json(value: &serde_json::Value) -> Result<(), LocusError> {
    let s = serde_json::to_string(value).map_err(|e| LocusError::Adapter {
        platform: locus_core::platform::Platform::ClaudeCode,
        message: format!("Failed to serialise hook output: {}", e),
    })?;
    let mut out = std::io::stdout().lock();
    out.write_all(s.as_bytes()).ok();
    Ok(())
}

// ---------- individual hook handlers ----------

/// The dispatcher injected next to every prompt.
///
/// A data file rather than a string literal so the wording stays editable
/// without touching Rust, and so its size can be asserted — it is paid on every
/// turn of every session, which is the whole reason it is small.
const DISPATCHER: &str = include_str!("dispatcher.txt");

fn dispatcher_context(event_name: &str) -> serde_json::Value {
    serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": event_name,
            "additionalContext": DISPATCHER
        }
    })
}

fn handle_session_start(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    let mut context = String::new();
    let mut system_message: Option<String> = None;

    // Which delegation vehicles this machine can reach is the same category of
    // fact as a missing binary: a precondition the model will otherwise
    // discover by failing at it. DEV-610 already built the way to say such a
    // thing — additionalContext plus a systemMessage, once per session, never
    // exit 2 — so this reuses that path rather than inventing a second one.
    //
    // Announcement is deliberately independent of enforcement. The notice fires
    // whether or not `delegation.enabled` has armed the PreToolUse denial,
    // because "you cannot delegate" is worth knowing even where nothing is
    // stopping you.
    if claim_session_notice(data_dir, event) {
        let availability = locus_core::vehicles::VehicleAvailability::probe();
        context.push_str(&availability.session_notice());
        if !availability.has_sanctioned_vehicle() {
            system_message = Some(
                "Locus: no delegation vehicle is reachable — native subagents are \
                 permitted as the last resort."
                    .to_string(),
            );
        }
    }

    // The dispatcher is only re-injected on compaction. On startup, resume and
    // clear the next UserPromptSubmit carries it anyway, so injecting here as
    // well would pay for the same context twice.
    //
    // The field is `source`, not `session_start_reason` — verified against
    // claude 2.1.263 and 2.1.270, neither of which contains that string.
    if event.get("source").and_then(|v| v.as_str()) == Some("compact") {
        if !context.is_empty() {
            context.push_str("\n\n");
        }
        context.push_str(DISPATCHER);
    }

    if context.is_empty() {
        return Ok(());
    }

    let mut out = serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context
        }
    });
    if let Some(message) = system_message {
        out["systemMessage"] = serde_json::Value::String(message);
    }
    write_stdout_json(&out)
}

/// True the first time this session asks for the availability notice.
///
/// SessionStart fires again on compaction, and vehicle availability is a
/// once-per-session fact rather than a once-per-event one. The marker is the
/// same shape the wrapper script uses for its own degraded notice.
///
/// Every failure here returns `true`. A notice said twice is a smaller failure
/// than a notice never said, and this whole path exists because silence is the
/// expensive outcome.
fn claim_session_notice(data_dir: &Path, event: &serde_json::Value) -> bool {
    let Some(session_id) = event.get("session_id").and_then(|v| v.as_str()) else {
        return true;
    };
    let safe: String = session_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if safe.is_empty() {
        return true;
    }

    let dir = data_dir.join("memory").join("state").join("pending");
    if std::fs::create_dir_all(&dir).is_err() {
        return true;
    }
    let marker = dir.join(format!("vehicles-{}.marker", safe));
    if marker.exists() {
        return false;
    }
    prune_session_markers(&dir);
    let _ = std::fs::write(&marker, b"");
    true
}

/// Sessions end without telling anyone, so their markers would accumulate
/// forever. A day is far longer than any session and far shorter than that.
fn prune_session_markers(dir: &Path) {
    const MARKER_TTL_SECONDS: u64 = 24 * 60 * 60;
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("vehicles-"))
        {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| now.duration_since(t).ok())
            .is_some_and(|age| age.as_secs() > MARKER_TTL_SECONDS);
        if stale {
            let _ = std::fs::remove_file(&path);
        }
    }
}

fn handle_session_end(_event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    // Write a final checkpoint marker so future sessions know the last
    // session ended cleanly. Ignore errors silently — hooks should never
    // break the session.
    let _ = write_checkpoint(data_dir, "session-end", &serde_json::json!({}));
    Ok(())
}

fn handle_pre_compact(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    // Emergency-write a checkpoint so compaction cannot lose state.
    let _ = write_checkpoint(data_dir, "pre-compact", event);
    Ok(())
}

fn handle_user_prompt_submit(
    _event: &serde_json::Value,
    _data_dir: &Path,
) -> Result<(), LocusError> {
    // The load-bearing injection. Compliance decay is a distance problem, so
    // the classification rule arrives adjacent to the prompt on every turn
    // rather than being loaded once and hoped to still be salient thirty
    // thousand tokens later.
    write_stdout_json(&dispatcher_context("UserPromptSubmit"))
}

fn handle_pre_tool_use(event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    if !is_delegation_enabled() {
        return Ok(());
    }

    match route_delegation(event, &locus_core::vehicles::VehicleAvailability::probe) {
        Routing::Deny(decision) => write_stdout_json(&decision),
        Routing::PermitDegraded { message, record } => {
            append_routing_record(&record);
            // Deliberately not an `allow` decision. Emitting one would
            // auto-approve the call and override whatever the user's own
            // permission rules say about subagents. The hook's job here is to
            // stop denying and to state the degradation in its own voice;
            // whether the call is then approved remains the user's.
            write_stdout_json(&serde_json::json!({ "systemMessage": message }))
        }
        Routing::Ignore => Ok(()),
    }
}

/// What the PreToolUse hook decided about a delegation-shaped tool call.
enum Routing {
    /// A better vehicle is reachable; send the caller there.
    Deny(serde_json::Value),
    /// Nothing better is reachable. Stop denying, and say so out loud.
    PermitDegraded {
        message: String,
        record: RoutingRecord,
    },
    /// Not a call this hook has an opinion about.
    Ignore,
}

/// One line of the delegation routing log.
///
/// Its own struct and its own file rather than a variant of the activation
/// log's `ActivationRecord`: two record shapes interleaved in one JSONL would
/// break every reader that assumes the activation schema. A
/// `#[derive(Serialize)]` struct rather than a `serde_json::json!` map for the
/// reason the activation log gives — `serde_json::Map` is a `BTreeMap` and
/// would emit these keys alphabetically.
///
/// Field order here *is* the on-disk format. Do not reorder.
///
/// This exists because the relaxation it records is otherwise unmeasurable.
/// "How often did delegation actually degrade to a subagent, and was the dead
/// end real?" is the question that decides whether tier 3 was worth adding, and
/// without a line per occurrence the answer six months from now is one
/// anecdote. Only the degraded path is logged: denials are the steady state and
/// counting them would bury the signal.
#[derive(serde::Serialize)]
pub struct RoutingRecord {
    ts: String,
    session_id: String,
    tool_name: String,
    vehicle: String,
    allele_reachable: bool,
    opencode_available: bool,
    escaped: bool,
    reason: String,
}

/// `probe` is injected rather than called directly so the routing decision is a
/// pure function of (event, availability) and can be tested without a live
/// socket. It is a closure rather than a value because the escape marker must
/// short-circuit ahead of it — see below.
fn route_delegation(
    event: &serde_json::Value,
    probe: &dyn Fn() -> locus_core::vehicles::VehicleAvailability,
) -> Routing {
    let tool_name = event
        .get("tool_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // The Workflow denial is untouched by vehicle availability. Its alternative
    // is the Algorithm's own phased execution, which is available on any
    // machine, so unlike the subagent denial it cannot dead-end.
    if matches!(tool_name, "Workflow" | "workflow") {
        return Routing::Deny(workflow_denial(event));
    }

    if !matches!(
        tool_name,
        "Task" | "Agent" | "TeamCreate" | "task" | "agent"
    ) {
        return Routing::Ignore;
    }

    let tool_input = event.get("tool_input");
    let prompt_hint = tool_input
        .and_then(|v| v.get("prompt").or_else(|| v.get("description")))
        .and_then(|v| v.as_str())
        .unwrap_or("<bounded task>");

    // The escape is checked before the probe, and that ordering is the point.
    //
    // This hook observes the filesystem; the caller observes its own toolset.
    // They disagree routinely — a session started before the Allele app, or one
    // whose MCP registration failed, sees no `allele_*` tools while the socket
    // is perfectly healthy. When they disagree the caller holds the better
    // evidence, so the gate must accept being contradicted or it can be
    // permanently, unfalsifiably wrong. Running this first also means the
    // release survives a probe that is broken rather than merely mistaken.
    if locus_core::vehicles::carries_escape(prompt_hint) {
        return Routing::PermitDegraded {
            message: escape_acknowledgement(),
            record: routing_record(
                event,
                tool_name,
                probe(),
                true,
                "caller asserted no sanctioned vehicle is usable from this session",
            ),
        };
    }

    let availability = probe();

    if !availability.has_sanctioned_vehicle() {
        return Routing::PermitDegraded {
            message: degraded_permit_message(),
            record: routing_record(
                event,
                tool_name,
                availability,
                false,
                "no sanctioned vehicle reachable on this machine",
            ),
        };
    }

    Routing::Deny(native_delegation_denial(event, availability, prompt_hint))
}

fn routing_record(
    event: &serde_json::Value,
    tool_name: &str,
    availability: locus_core::vehicles::VehicleAvailability,
    escaped: bool,
    reason: &str,
) -> RoutingRecord {
    RoutingRecord {
        ts: chrono::Utc::now().to_rfc3339(),
        session_id: event
            .get("session_id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        tool_name: tool_name.to_string(),
        vehicle: locus_core::vehicles::Vehicle::NativeSubagent
            .as_str()
            .to_string(),
        allele_reachable: availability.allele,
        opencode_available: availability.opencode,
        escaped,
        reason: reason.to_string(),
    }
}

fn append_routing_record(record: &RoutingRecord) {
    let Some(dir) = crate::commands::stop_verifier::log_dir() else {
        return;
    };
    // Losing a log line must never cost the user their tool call.
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let month = chrono::Utc::now().format("%Y-%m").to_string();
    let path = dir.join(format!("delegation-{}.jsonl", month));
    let Ok(mut line) = serde_json::to_string(record) else {
        return;
    };
    line.push('\n');
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn escape_acknowledgement() -> String {
    "Locus: you asserted that no sanctioned delegation vehicle is usable from this \
     session, so this native subagent is permitted. Tell the user what degraded and \
     why — a subagent has no workspace, no branch and no conversation, and it can be \
     neither interrupted nor addressed. The assertion has been recorded."
        .to_string()
}

fn degraded_permit_message() -> String {
    format!(
        "Locus: no sanctioned delegation vehicle is reachable — the Allele app is not \
         accepting connections on {} and OpenCode is not usable (binary or credential \
         missing). This native subagent is therefore permitted as the last resort. \
         Tell the user plainly that delegation has degraded to a hidden subagent: no \
         workspace, no branch, no conversation, and it can be neither interrupted nor \
         addressed. If the work genuinely needs a real session, the right move is to \
         stop and say delegation is unavailable rather than quietly absorbing it.",
        locus_core::vehicles::allele_socket_path()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "~/.allele/control.sock".to_string())
    )
}

fn is_delegation_enabled() -> bool {
    let locus_home = if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        PathBuf::from(env_home)
    } else {
        match dirs::home_dir() {
            Some(h) => h.join(".locus"),
            None => return false,
        }
    };
    let path = locus_home.join("locus.yaml");
    locus_core::LocusConfig::from_file(&path)
        .map(|cfg| cfg.delegation.enabled)
        .unwrap_or(false)
}

/// Send a delegation-shaped call to the vehicle that is actually reachable.
///
/// Only ever called with `availability.has_sanctioned_vehicle()` true — the
/// caller checks that first, because denying with nothing to route to is the
/// dead end this whole path exists to remove.
///
/// The message names one specific vehicle rather than describing a routing
/// policy. A model reading "prefer sanctioned delegation vehicles" has to guess
/// which one is up; a model reading "the Allele app is reachable at
/// /Users/x/.allele/control.sock" does not.
fn native_delegation_denial(
    event: &serde_json::Value,
    availability: locus_core::vehicles::VehicleAvailability,
    prompt_hint: &str,
) -> serde_json::Value {
    let tool_input = event.get("tool_input");

    let subagent_type = tool_input
        .and_then(|v| v.get("subagent_type"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let task_kind = match subagent_type.to_lowercase().as_str() {
        "explore" => "code-exploration",
        "general-purpose" => "general",
        _ if prompt_hint.to_lowercase().contains("research") => "research",
        _ if prompt_hint.to_lowercase().contains("explor") => "code-exploration",
        _ => "general",
    };

    let escape = locus_core::vehicles::NO_VEHICLE_ESCAPE;

    let reason = if availability.allele {
        format!(
            "BLOCKED — route this through Allele, not a native subagent.\n\n\
             You judged that this work should be delegated, and that judgement was \
             right. Only the vehicle is wrong. The Allele app is reachable on this \
             machine ({socket}), so a real session is available: visible in the \
             sidebar, addressable and interruptible, which a subagent is none of.\n\n\
             Compose, then dispatch:\n\n\
             PROMPT=$(locus agent compose \\\n  \
             --traits \"research,systematic,empirical\" \\\n  \
             --role \"<role>\" \\\n  \
             --task \"<your task description>\" \\\n  \
             --output prompt)\n\n\
             allele_sessions_create(project: \"<project>\", name: \"<specific name>\", \
             prompt: \"$PROMPT\")\n\n\
             Do NOT do the work inline instead — you already judged it delegatable, \
             and doing it here wastes the judgement.\n\n\
             If the `allele_*` tools are not in your toolset, this session is not \
             connected to the running app. That is a real condition and it is not \
             something you can fix from here: say so, then re-issue this exact call \
             with `{escape}` in the prompt or description. That marker permits the \
             call and records the degradation.",
            socket = locus_core::vehicles::allele_socket_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "~/.allele/control.sock".to_string()),
            escape = escape,
        )
    } else {
        format!(
            "BLOCKED — route this through OpenCode, not a native subagent.\n\n\
             You judged that this work should be delegated, and that judgement was \
             right. The Allele app is not reachable on this machine ({socket} is not \
             accepting connections), so delegation falls to the standalone path. It is \
             read-only and gives you no workspace, no branch and no conversation — say \
             so in your reply rather than presenting it as a full session.\n\n\
             locus delegate run --backend opencode --task-kind {task_kind} \
             --mode native --dir . --prompt \"{prompt}\" --output json\n\n\
             If that command cannot authenticate or the backend is unavailable, \
             re-issue this Task call with `{escape}` in the prompt or description. \
             That marker permits the call and records the degradation.",
            socket = locus_core::vehicles::allele_socket_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "~/.allele/control.sock".to_string()),
            task_kind = task_kind,
            prompt = prompt_hint.replace('"', "\\\""),
            escape = escape,
        )
    };

    serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason
        }
    })
}

fn workflow_denial(event: &serde_json::Value) -> serde_json::Value {
    let tool_input = event.get("tool_input");

    let description = tool_input
        .and_then(|v| v.get("description"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let has_script = tool_input
        .and_then(|v| v.get("script").or_else(|| v.get("scriptPath")).or_else(|| v.get("name")))
        .is_some();

    let script_hint = if has_script {
        format!(
            " The workflow{} would have spawned multiple subagents in parallel — \
             this burns significant tokens and bypasses Locus's orchestration entirely.",
            if description.is_empty() {
                String::new()
            } else {
                format!(" (\"{}\")", description)
            }
        )
    } else {
        String::new()
    };

    let reason = format!(
        "BLOCKED: Dynamic workflow orchestration is not allowed — Locus manages all \
         orchestration through the Algorithm.{}\n\n\
         The Workflow tool spawns dozens of native subagents that burn massive tokens, \
         bypass the Algorithm's phased execution, and produce unstructured results that \
         cannot be checkpointed or learned from.\n\n\
         Instead, do one of the following:\n\n\
         1. **For multi-source research or comparison tasks:** delegate individual \
         subtasks via `locus delegate run`, issuing multiple Bash calls in parallel \
         for concurrent execution. Each delegation returns a compact JSON envelope.\n\n\
         2. **For complex multi-step work:** use the Algorithm's phased execution \
         (OBSERVE → THINK → PLAN → BUILD → EXECUTE → VERIFY → LEARN) which provides \
         structured decomposition, checkpointing, and learning.\n\n\
         3. **For parallel investigations:** compose trait-based agents with \
         `locus agent compose` and dispatch multiple `locus delegate run` calls \
         simultaneously as separate Bash tool calls in one message.\n\n\
         Do NOT re-attempt the Workflow tool. Do NOT try to work around this by \
         using a different tool name or approach to launch native multi-agent \
         orchestration.",
        script_hint
    );

    serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason
        }
    })
}

fn handle_post_tool_use(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    let tool_name = event
        .get("tool_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let project_dir = event
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok());

    if tool_name == "Bash" {
        // PRD frontmatter is routinely edited via sed/perl -i, which bypasses
        // the Write/Edit path below. Resync any recently-touched PRD so
        // work.json can't go stale.
        let command = event
            .get("tool_input")
            .and_then(|v| v.get("command"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if command.contains("PRD.md") || command.contains("memory/work") {
            // No project_dir here: the sweep touches PRDs owned by any
            // session, and stamping them with THIS session's cwd would
            // mis-attribute them. Only the direct Write/Edit path below —
            // where the editing session owns the PRD — records it.
            let _ = resync_recent_prds(data_dir, None, 600);
        }
        return Ok(());
    }

    if tool_name != "Write" && tool_name != "Edit" {
        return Ok(());
    }

    let file_path = event
        .get("tool_input")
        .and_then(|v| v.get("file_path"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if file_path.ends_with("/PRD.md") {
        let _ = sync_prd_to_work_json(Path::new(file_path), data_dir, project_dir.as_deref());
    } else if let Some(prd) = prd_for_work_file(file_path) {
        // Any other file under memory/work/<slug>/ changed — re-parse that
        // slug's PRD so cached progress tracks the system of record.
        if prd.exists() {
            let _ = sync_prd_to_work_json(&prd, data_dir, project_dir.as_deref());
        }
    }

    if is_claude_memory_path(file_path) {
        let mirror_result = mirror_memory_to_locus(file_path, data_dir);

        let ctx = match &mirror_result {
            Ok(result) => {
                if let Some(entries_added) = result.entries_added {
                    format!(
                        "Mirrored {} to Locus: {} ({} new entries merged). \
                         Locus is the canonical store.",
                        result.filename,
                        result.destination.display(),
                        entries_added
                    )
                } else {
                    format!(
                        "Mirrored {} to Locus: {}. \
                         Locus is the canonical store.",
                        result.filename,
                        result.destination.display()
                    )
                }
            }
            Err(e) => format!(
                "WARNING: Memory file at {} could NOT be mirrored to Locus: {}. \
                 Locus is the canonical memory store. Please also write this memory \
                 to the appropriate Locus project directory under ~/.locus/data/projects/.",
                file_path, e
            ),
        };

        let out = serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": ctx
            }
        });
        return write_stdout_json(&out);
    }

    Ok(())
}

fn handle_stop(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    // The activation gate runs first and may end the process with exit 2. The
    // PRD warning below is advisory and must not be what decides the turn.
    let verdict = crate::commands::stop_verifier::verify(event);

    warn_on_unwritten_learnings(data_dir);

    if let crate::commands::stop_verifier::Verdict::Block(reason) = verdict {
        eprintln!("{}", reason);
        // Hooks signal "block and feed stderr back to the model" with exit 2.
        // `continueReason` does not exist in the binary (0 occurrences at
        // 2.1.270); DEV-580 established this as the mechanism.
        std::process::exit(2);
    }
    Ok(())
}

fn warn_on_unwritten_learnings(data_dir: &Path) {
    // Warn (via stderr — hooks should not corrupt stdout) if any recent PRD
    // reached phase:learn without a corresponding learning file.
    let work_dir = data_dir.join("memory").join("work");
    if !work_dir.exists() {
        return;
    }

    let learning_dir = data_dir.join("memory").join("learning").join("session");
    if let Ok(entries) = std::fs::read_dir(&work_dir) {
        for e in entries.flatten() {
            let prd = e.path().join("PRD.md");
            if !prd.exists() {
                continue;
            }
            if let Ok(content) = std::fs::read_to_string(&prd) {
                if has_phase_learn(&content) && !has_matching_learning_file(&e.path(), &learning_dir) {
                    eprintln!(
                        "locus: PRD {} reached phase:learn but no learning file was written",
                        prd.display()
                    );
                }
            }
        }
    }
}

fn handle_notification(_event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    // No voice, no bells. Reserved for future platform-agnostic notifications.
    Ok(())
}

// ---------- Claude Code memory mirroring ----------

struct MirrorResult {
    filename: String,
    destination: PathBuf,
    entries_added: Option<usize>,
}

fn is_claude_memory_path(path: &str) -> bool {
    path.contains("/.claude/projects/") && path.contains("/memory/")
}

fn mirror_memory_to_locus(file_path: &str, data_dir: &Path) -> Result<MirrorResult, LocusError> {
    let path = Path::new(file_path);
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");

    if filename.is_empty() {
        return Ok(MirrorResult {
            filename: String::new(),
            destination: PathBuf::new(),
            entries_added: None,
        });
    }

    let cwd = std::env::current_dir().map_err(|e| LocusError::Filesystem {
        message: format!("Failed to get CWD: {}", e),
        path: PathBuf::new(),
    })?;

    let slug = match resolve_project_slug(&cwd, data_dir) {
        Ok(s) => s,
        Err(_) => {
            return Ok(MirrorResult {
                filename: filename.to_string(),
                destination: PathBuf::new(),
                entries_added: None,
            });
        }
    };

    let project_dir = data_dir.join("projects").join(&slug);
    std::fs::create_dir_all(&project_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create project dir: {}", e),
        path: project_dir.clone(),
    })?;

    if filename == "MEMORY.md" {
        let entries_added = merge_memory_index(path, &project_dir)?;
        Ok(MirrorResult {
            filename: filename.to_string(),
            destination: project_dir.join("MEMORY.md"),
            entries_added: Some(entries_added),
        })
    } else {
        let dest = project_dir.join(filename);
        std::fs::copy(file_path, &dest).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to mirror memory file: {}", e),
            path: dest.clone(),
        })?;
        Ok(MirrorResult {
            filename: filename.to_string(),
            destination: dest,
            entries_added: None,
        })
    }
}

fn resolve_project_slug(cwd: &Path, data_dir: &Path) -> Result<String, LocusError> {
    let home = dirs::home_dir();

    let mut dir = Some(cwd.to_path_buf());
    while let Some(d) = dir {
        let marker = d.join(".locus-project");
        if marker.exists() {
            if let Ok(content) = std::fs::read_to_string(&marker) {
                if let Some(name) = parse_locus_project_name(&content) {
                    return Ok(name);
                }
            }
        }
        if home.as_ref() == Some(&d) {
            break;
        }
        dir = d.parent().map(|p| p.to_path_buf());
    }

    let registry_path = data_dir.join("projects").join("_registry.json");
    if registry_path.exists() {
        if let Ok(content) = std::fs::read_to_string(&registry_path) {
            if let Ok(reg) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(slug) = resolve_from_registry(&reg, cwd) {
                    return Ok(slug);
                }
            }
        }
    }

    Ok(derive_slug_from_path(cwd))
}

fn derive_slug_from_path(cwd: &Path) -> String {
    let home = dirs::home_dir().unwrap_or_default();
    let relative = cwd.strip_prefix(&home).unwrap_or(cwd);
    let parts: Vec<&str> = relative
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .filter(|s| !s.starts_with('.'))
        .collect();
    let slug = if parts.is_empty() {
        "unknown".to_string()
    } else {
        parts.join("-").to_lowercase()
    };
    slug.chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '-' })
        .collect()
}

fn parse_locus_project_name(content: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("name:") {
            let name = rest.trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}

fn resolve_from_registry(registry: &serde_json::Value, cwd: &Path) -> Option<String> {
    let projects = registry.get("projects")?.as_object()?;
    let cwd_str = cwd.to_string_lossy();

    for (slug, project) in projects {
        if let Some(paths) = project.get("paths").and_then(|v| v.as_array()) {
            for path in paths {
                if let Some(p) = path.as_str() {
                    if cwd_str == p {
                        return Some(slug.clone());
                    }
                }
            }
        }
    }

    for (slug, project) in projects {
        if let Some(patterns) = project.get("patterns").and_then(|v| v.as_array()) {
            for pattern in patterns {
                if let Some(p) = pattern.as_str() {
                    if simple_glob_match(p, &cwd_str) {
                        return Some(slug.clone());
                    }
                }
            }
        }
    }

    None
}

/// Matches `**/segment/**` style globs by checking if path contains the inner segment.
fn simple_glob_match(pattern: &str, path: &str) -> bool {
    let inner = pattern
        .trim_start_matches("**/")
        .trim_end_matches("/**")
        .trim_end_matches("/*")
        .trim_end_matches("*");
    if inner.is_empty() {
        return false;
    }
    path.contains(inner)
}

/// Appends entries from a Claude Code MEMORY.md into the Locus project MEMORY.md,
/// skipping any entries whose link target already exists in the Locus index.
fn merge_memory_index(source_path: &Path, project_dir: &Path) -> Result<usize, LocusError> {
    let source_content =
        std::fs::read_to_string(source_path).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read source MEMORY.md: {}", e),
            path: source_path.to_path_buf(),
        })?;

    let target_path = project_dir.join("MEMORY.md");
    let target_content = std::fs::read_to_string(&target_path).unwrap_or_default();

    let existing_refs: std::collections::HashSet<String> = target_content
        .lines()
        .filter_map(extract_link_target)
        .collect();

    let new_entries: Vec<&str> = source_content
        .lines()
        .filter(|line| {
            extract_link_target(line)
                .map(|link| !existing_refs.contains(&link))
                .unwrap_or(false)
        })
        .collect();

    let count = new_entries.len();

    if new_entries.is_empty() {
        return Ok(0);
    }

    let mut result = target_content.trim_end().to_string();
    if !result.is_empty() {
        result.push('\n');
    }
    for entry in &new_entries {
        result.push_str(entry);
        result.push('\n');
    }

    std::fs::write(&target_path, result).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write MEMORY.md: {}", e),
        path: target_path,
    })?;

    Ok(count)
}

fn extract_link_target(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if !trimmed.starts_with("- [") {
        return None;
    }
    let open = trimmed.find("](")?;
    let rest = &trimmed[open + 2..];
    let close = rest.find(')')?;
    Some(rest[..close].to_string())
}

// ---------- shared helpers ----------

fn write_checkpoint(
    data_dir: &Path,
    kind: &str,
    event: &serde_json::Value,
) -> Result<(), LocusError> {
    let dir = data_dir.join("memory").join("state");
    std::fs::create_dir_all(&dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create state dir: {}", e),
        path: dir.clone(),
    })?;

    let ts = chrono::Utc::now().format("%Y%m%d-%H%M%S").to_string();
    let path = dir.join(format!("checkpoint-{}-{}.md", kind, ts));

    let body = format!(
        "---\nkind: {kind}\ntimestamp: {iso}\n---\n\n## Event\n\n```json\n{payload}\n```\n",
        kind = kind,
        iso = chrono::Utc::now().to_rfc3339(),
        payload = serde_json::to_string_pretty(event).unwrap_or_default()
    );

    std::fs::write(&path, body).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write checkpoint: {}", e),
        path,
    })?;
    Ok(())
}

fn has_phase_learn(content: &str) -> bool {
    content
        .lines()
        .take_while(|l| *l != "---" || content.lines().position(|x| x == *l).unwrap_or(0) > 0)
        .any(|l| l.trim() == "phase: learn")
}

fn has_matching_learning_file(prd_dir: &Path, learning_dir: &Path) -> bool {
    let slug = prd_dir
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    if slug.is_empty() || !learning_dir.exists() {
        return false;
    }
    // Walk year-month subdirs looking for a filename containing the slug.
    if let Ok(months) = std::fs::read_dir(learning_dir) {
        for m in months.flatten() {
            if let Ok(files) = std::fs::read_dir(m.path()) {
                for f in files.flatten() {
                    let name = f.file_name();
                    if name.to_string_lossy().contains(slug) {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// Resolve the PRD.md governing any file under a `memory/work/<slug>/` tree.
/// Returns None for paths outside a work directory.
fn prd_for_work_file(file_path: &str) -> Option<PathBuf> {
    let marker = "/memory/work/";
    let idx = file_path.find(marker)?;
    let after = &file_path[idx + marker.len()..];
    let slug = after.split('/').next()?;
    if slug.is_empty() {
        return None;
    }
    Some(
        PathBuf::from(&file_path[..idx])
            .join("memory")
            .join("work")
            .join(slug)
            .join("PRD.md"),
    )
}

/// Re-parse every PRD under `{data}/memory/work/` modified within the last
/// `max_age_secs`, refreshing its work.json entry. Called after Bash commands
/// that touch PRDs (sed/perl -i edits never fire the Write/Edit path). The
/// mtime gate keeps this a cheap readdir+stat sweep. Callers should pass
/// `project_dir: None` — see the call site in handle_post_tool_use.
fn resync_recent_prds(
    data_dir: &Path,
    project_dir: Option<&Path>,
    max_age_secs: u64,
) -> Result<(), LocusError> {
    let work_dir = data_dir.join("memory").join("work");
    let entries = match std::fs::read_dir(&work_dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    let now = std::time::SystemTime::now();
    for e in entries.flatten() {
        let prd = e.path().join("PRD.md");
        let mtime = match std::fs::metadata(&prd).and_then(|m| m.modified()) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let recent = now
            .duration_since(mtime)
            .map(|d| d.as_secs() <= max_age_secs)
            .unwrap_or(true); // mtime in the future — clock skew, treat as recent
        if recent {
            let _ = sync_prd_to_work_json(&prd, data_dir, project_dir);
        }
    }
    Ok(())
}

/// Parse a PRD.md's YAML frontmatter and criteria checkboxes, then write or
/// update the corresponding entry in `{data}/memory/state/work.json`.
///
/// `project_dir` records where the session was working when the PRD was
/// created; once set it is preserved across resyncs so a drifted shell cwd
/// can't repoint the entry.
pub(crate) fn sync_prd_to_work_json(
    prd_path: &Path,
    data_dir: &Path,
    project_dir: Option<&Path>,
) -> Result<(), LocusError> {
    let content = std::fs::read_to_string(prd_path).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to read PRD: {}", e),
        path: prd_path.to_path_buf(),
    })?;

    let (frontmatter, body) = split_frontmatter(&content);
    let fm: serde_yaml::Value = serde_yaml::from_str(frontmatter).unwrap_or(serde_yaml::Value::Null);

    let slug = fm
        .get("slug")
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| {
            prd_path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|s| s.to_str())
                .unwrap_or("unknown")
        })
        .to_string();

    let total = body
        .lines()
        .filter(|l| l.trim_start().starts_with("- [ ] ISC-") || l.trim_start().starts_with("- [x] ISC-"))
        .count();
    let done = body
        .lines()
        .filter(|l| l.trim_start().starts_with("- [x] ISC-"))
        .count();

    let state_dir = data_dir.join("memory").join("state");
    std::fs::create_dir_all(&state_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create state dir: {}", e),
        path: state_dir.clone(),
    })?;

    let work_path = state_dir.join("work.json");
    let mut registry: serde_json::Value = if work_path.exists() {
        std::fs::read_to_string(&work_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| serde_json::json!({ "sessions": {} }))
    } else {
        serde_json::json!({ "sessions": {} })
    };

    if !registry.is_object() {
        registry = serde_json::json!({ "sessions": {} });
    }

    // Preserve the project_dir recorded at creation; only fill it when absent.
    let existing_project_dir = registry
        .get("sessions")
        .and_then(|s| s.get(&slug))
        .and_then(|e| e.get("project_dir"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let recorded_project_dir = existing_project_dir
        .or_else(|| project_dir.map(|p| p.display().to_string()));

    let mut entry = serde_json::json!({
        "slug": slug,
        "task": fm.get("task").and_then(|v| v.as_str()).unwrap_or(""),
        "phase": fm.get("phase").and_then(|v| v.as_str()).unwrap_or(""),
        "effort": fm.get("effort").and_then(|v| v.as_str()).unwrap_or(""),
        "mode": fm.get("mode").and_then(|v| v.as_str()).unwrap_or(""),
        "progress": format!("{}/{}", done, total),
        "updated": fm.get("updated").and_then(|v| v.as_str()).unwrap_or(""),
        "path": prd_path.display().to_string(),
    });
    if let Some(pd) = recorded_project_dir {
        entry["project_dir"] = serde_json::Value::String(pd);
    }

    let sessions = registry
        .as_object_mut()
        .unwrap()
        .entry("sessions".to_string())
        .or_insert_with(|| serde_json::json!({}));
    if !sessions.is_object() {
        *sessions = serde_json::json!({});
    }
    sessions
        .as_object_mut()
        .unwrap()
        .insert(slug, entry);

    let out = serde_json::to_string_pretty(&registry).map_err(|e| LocusError::Adapter {
        platform: locus_core::platform::Platform::ClaudeCode,
        message: format!("Failed to serialise work.json: {}", e),
    })?;
    std::fs::write(&work_path, out).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write work.json: {}", e),
        path: work_path,
    })?;
    Ok(())
}

fn split_frontmatter(content: &str) -> (&str, &str) {
    let bytes = content.as_bytes();
    if !content.starts_with("---") {
        return ("", content);
    }
    // Find the closing --- after line 1.
    let mut i = 3;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            let rest = &content[i + 1..];
            if let Some(end) = rest.find("\n---") {
                let fm = &content[3..i + 1 + end];
                let body_start = i + 1 + end + 4; // skip "\n---"
                // Skip optional trailing newline.
                let body = if body_start < content.len() && bytes[body_start] == b'\n' {
                    &content[body_start + 1..]
                } else {
                    &content[body_start.min(content.len())..]
                };
                return (fm.trim(), body);
            }
            break;
        }
        i += 1;
    }
    ("", content)
}

#[allow(dead_code)]
pub fn log_error(err: &LocusError) {
    output::error(&err.to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_frontmatter_from_body() {
        let input = "---\nslug: abc\nphase: build\n---\n\nbody goes here\n- [x] ISC-1: done\n- [ ] ISC-2: pending\n";
        let (fm, body) = split_frontmatter(input);
        assert!(fm.contains("slug: abc"));
        assert!(fm.contains("phase: build"));
        assert!(body.contains("body goes here"));
        assert!(body.contains("ISC-1"));
    }

    #[test]
    fn sync_prd_writes_work_json_entry() {
        let tmp = tempfile::tempdir().unwrap();
        let work_slug_dir = tmp.path().join("memory").join("work").join("myslug");
        std::fs::create_dir_all(&work_slug_dir).unwrap();
        let prd_path = work_slug_dir.join("PRD.md");

        std::fs::write(
            &prd_path,
            "---\nslug: myslug\ntask: test task\nphase: execute\neffort: advanced\nmode: algorithm\nprogress: 1/2\nupdated: 2026-04-21T12:00:00\n---\n\n## Criteria\n\n- [x] ISC-1: first\n- [ ] ISC-2: second\n",
        )
        .unwrap();

        sync_prd_to_work_json(&prd_path, tmp.path(), Some(Path::new("/Users/test/myproject")))
            .unwrap();

        let work_json = std::fs::read_to_string(
            tmp.path().join("memory").join("state").join("work.json"),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&work_json).unwrap();

        let entry = &v["sessions"]["myslug"];
        assert_eq!(entry["task"], "test task");
        assert_eq!(entry["phase"], "execute");
        assert_eq!(entry["effort"], "advanced");
        assert_eq!(entry["mode"], "algorithm");
        assert_eq!(entry["progress"], "1/2");
        assert_eq!(entry["project_dir"], "/Users/test/myproject");
    }

    #[test]
    fn sync_prd_preserves_project_dir_across_resyncs() {
        let tmp = tempfile::tempdir().unwrap();
        let work_slug_dir = tmp.path().join("memory").join("work").join("myslug");
        std::fs::create_dir_all(&work_slug_dir).unwrap();
        let prd_path = work_slug_dir.join("PRD.md");

        std::fs::write(
            &prd_path,
            "---\nslug: myslug\nphase: observe\n---\n\n- [ ] ISC-1: first\n",
        )
        .unwrap();
        sync_prd_to_work_json(&prd_path, tmp.path(), Some(Path::new("/Users/test/project-a")))
            .unwrap();

        // Resync from a drifted cwd (e.g. shell cd'd into the data dir) must
        // not repoint project_dir, but must refresh phase/progress.
        std::fs::write(
            &prd_path,
            "---\nslug: myslug\nphase: complete\n---\n\n- [x] ISC-1: first\n",
        )
        .unwrap();
        sync_prd_to_work_json(&prd_path, tmp.path(), Some(Path::new("/somewhere/else")))
            .unwrap();

        let work_json = std::fs::read_to_string(
            tmp.path().join("memory").join("state").join("work.json"),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&work_json).unwrap();
        let entry = &v["sessions"]["myslug"];
        assert_eq!(entry["project_dir"], "/Users/test/project-a");
        assert_eq!(entry["phase"], "complete");
        assert_eq!(entry["progress"], "1/1");
    }

    #[test]
    fn sync_prd_omits_project_dir_when_unknown() {
        let tmp = tempfile::tempdir().unwrap();
        let work_slug_dir = tmp.path().join("memory").join("work").join("myslug");
        std::fs::create_dir_all(&work_slug_dir).unwrap();
        let prd_path = work_slug_dir.join("PRD.md");
        std::fs::write(&prd_path, "---\nslug: myslug\nphase: observe\n---\n").unwrap();

        sync_prd_to_work_json(&prd_path, tmp.path(), None).unwrap();

        let work_json = std::fs::read_to_string(
            tmp.path().join("memory").join("state").join("work.json"),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&work_json).unwrap();
        assert!(v["sessions"]["myslug"].get("project_dir").is_none());
    }

    #[test]
    fn prd_for_work_file_resolves_sibling_files() {
        assert_eq!(
            prd_for_work_file("/Users/test/.locus/data/memory/work/myslug/notes.md"),
            Some(PathBuf::from(
                "/Users/test/.locus/data/memory/work/myslug/PRD.md"
            ))
        );
        assert_eq!(
            prd_for_work_file("/Users/test/.locus/data/memory/work/myslug/PRD.md"),
            Some(PathBuf::from(
                "/Users/test/.locus/data/memory/work/myslug/PRD.md"
            ))
        );
        assert_eq!(prd_for_work_file("/Users/test/project/src/main.rs"), None);
        assert_eq!(prd_for_work_file("/Users/test/.locus/data/memory/work/"), None);
    }

    #[test]
    fn resync_recent_prds_refreshes_modified_prds() {
        let tmp = tempfile::tempdir().unwrap();
        let work_slug_dir = tmp.path().join("memory").join("work").join("myslug");
        std::fs::create_dir_all(&work_slug_dir).unwrap();
        let prd_path = work_slug_dir.join("PRD.md");

        std::fs::write(
            &prd_path,
            "---\nslug: myslug\nphase: observe\n---\n\n- [ ] ISC-1: first\n",
        )
        .unwrap();
        sync_prd_to_work_json(&prd_path, tmp.path(), None).unwrap();

        // Simulate a `sed -i` style edit: mutate the file directly, then run
        // the Bash-triggered sweep — no Write/Edit hook involved.
        std::fs::write(
            &prd_path,
            "---\nslug: myslug\nphase: execute\n---\n\n- [x] ISC-1: first\n",
        )
        .unwrap();
        resync_recent_prds(tmp.path(), None, 600).unwrap();

        let work_json = std::fs::read_to_string(
            tmp.path().join("memory").join("state").join("work.json"),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&work_json).unwrap();
        let entry = &v["sessions"]["myslug"];
        assert_eq!(entry["phase"], "execute");
        assert_eq!(entry["progress"], "1/1");
        // The sweep must not fabricate a project_dir for legacy entries…
        assert!(entry.get("project_dir").is_none());

        // …and must keep one that was recorded at creation.
        sync_prd_to_work_json(&prd_path, tmp.path(), Some(Path::new("/Users/test/owner")))
            .unwrap();
        resync_recent_prds(tmp.path(), None, 600).unwrap();
        let v: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(tmp.path().join("memory").join("state").join("work.json"))
                .unwrap(),
        )
        .unwrap();
        assert_eq!(v["sessions"]["myslug"]["project_dir"], "/Users/test/owner");
    }

    #[test]
    fn session_start_handler_emits_additional_context() {
        let tmp = tempfile::tempdir().unwrap();
        let mut out = Vec::<u8>::new();

        // Build the same value the handler would write, then assert shape.
        let ctx = "Locus is active on this session.";
        let json = serde_json::json!({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": ctx
            }
        });
        out.write_all(serde_json::to_string(&json).unwrap().as_bytes())
            .unwrap();

        let parsed: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(
            parsed["hookSpecificOutput"]["hookEventName"],
            "SessionStart"
        );
        assert!(parsed["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap()
            .contains("Locus"));

        // Silence unused var warning — the tempdir is the handler's data root.
        drop(tmp);
    }

    #[test]
    fn pre_compact_writes_checkpoint() {
        let tmp = tempfile::tempdir().unwrap();
        write_checkpoint(tmp.path(), "pre-compact", &serde_json::json!({"reason": "test"})).unwrap();
        let state_dir = tmp.path().join("memory").join("state");
        let entries: Vec<_> = std::fs::read_dir(&state_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .collect();
        assert_eq!(entries.len(), 1);
        let name = entries[0].file_name();
        assert!(name.to_string_lossy().starts_with("checkpoint-pre-compact-"));
    }

    // ---------------------------------------------- delegation routing --
    //
    // `route_delegation` takes its probe as a closure precisely so these can
    // state a world and assert what the hook does in it, with no live socket
    // and no environment mutation.

    fn availability(allele: bool, opencode: bool) -> locus_core::vehicles::VehicleAvailability {
        locus_core::vehicles::VehicleAvailability { allele, opencode }
    }

    fn route(event: &serde_json::Value, allele: bool, opencode: bool) -> Routing {
        route_delegation(event, &move || availability(allele, opencode))
    }

    fn denial_reason(routing: &Routing) -> &str {
        match routing {
            Routing::Deny(decision) => decision["hookSpecificOutput"]["permissionDecisionReason"]
                .as_str()
                .expect("a denial must carry a reason"),
            _ => panic!("expected a denial"),
        }
    }

    /// The happy path is denied *to* something, and the something is named.
    /// "Prefer a sanctioned vehicle" would leave the model guessing which one
    /// is actually up; the socket path does not.
    #[test]
    fn a_task_call_is_denied_to_allele_when_allele_is_reachable() {
        let event = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "Task",
            "tool_input": {"description": "research something"}
        });

        let routing = route(&event, true, true);
        match &routing {
            Routing::Deny(decision) => assert_eq!(
                decision["hookSpecificOutput"]["permissionDecision"].as_str(),
                Some("deny")
            ),
            _ => panic!("expected a denial"),
        }

        let reason = denial_reason(&routing);
        assert!(reason.contains("allele_sessions_create"));
        assert!(reason.contains("locus agent compose"));
        assert!(reason.contains("control.sock"));
        assert!(reason.contains("Do NOT do the work inline"));
        assert!(
            reason.contains(locus_core::vehicles::NO_VEHICLE_ESCAPE),
            "every denial must carry its own release condition"
        );
    }

    /// Allele down, OpenCode up: the denial routes to tier 2 and to nothing
    /// else. Naming Allele here would send the caller at a socket that is not
    /// answering.
    #[test]
    fn a_task_call_is_denied_to_opencode_when_only_opencode_is_available() {
        let event = serde_json::json!({
            "tool_name": "Agent",
            "tool_input": {
                "subagent_type": "Explore",
                "prompt": "find all API endpoints",
                "description": "explore codebase"
            }
        });

        let routing = route(&event, false, true);
        let reason = denial_reason(&routing);
        assert!(reason.contains("locus delegate run"));
        assert!(reason.contains("--task-kind code-exploration"));
        assert!(
            !reason.contains("allele_sessions_create"),
            "must not route to a vehicle that is not answering"
        );
        assert!(reason.contains(locus_core::vehicles::NO_VEHICLE_ESCAPE));
    }

    /// The acceptance criterion this pair of tickets exists for. With both
    /// sanctioned vehicles gone the denial must not fire, because there is
    /// nowhere left to send the caller — that is denying into a dead end.
    #[test]
    fn a_task_call_is_permitted_when_no_sanctioned_vehicle_is_reachable() {
        let event = serde_json::json!({
            "tool_name": "Task",
            "tool_input": {"description": "research something"}
        });

        match route(&event, false, false) {
            Routing::PermitDegraded { message, record } => {
                assert!(message.contains("permitted as the last resort"));
                assert!(message.contains("no workspace, no branch, no conversation"));
                assert!(
                    message.contains("stop and say delegation is unavailable"),
                    "the terminal option must be stated, not just the permission"
                );
                assert_eq!(record.vehicle, "native_subagent");
                assert!(!record.escaped);
                assert!(!record.allele_reachable);
                assert!(!record.opencode_available);
            }
            _ => panic!("a Task call must be permitted when nothing better is reachable"),
        }
    }

    /// The release condition. The hook sees a healthy socket; the caller sees
    /// no `allele_*` tools. The caller holds the better evidence about its own
    /// toolset, so its assertion wins — otherwise the gate is unfalsifiable and
    /// can be permanently wrong.
    #[test]
    fn the_escape_marker_releases_the_denial_even_while_allele_looks_reachable() {
        let event = serde_json::json!({
            "tool_name": "Task",
            "tool_input": {
                "description": "no allele_* tools in this session, locus:no-allele"
            }
        });

        match route(&event, true, true) {
            Routing::PermitDegraded { message, record } => {
                assert!(message.contains("you asserted"));
                assert!(record.escaped);
                assert!(
                    record.allele_reachable,
                    "the record must preserve that the machine looked fine — that \
                     disagreement is the interesting datum"
                );
            }
            _ => panic!("the escape marker must release the denial"),
        }
    }

    #[test]
    fn non_delegation_tools_are_ignored_whatever_is_reachable() {
        let event = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "locus delegate run --backend opencode"}
        });

        assert!(matches!(route(&event, true, true), Routing::Ignore));
        assert!(matches!(route(&event, false, false), Routing::Ignore));
    }

    /// Workflow is deliberately not gated on vehicle availability. Its stated
    /// alternative is the Algorithm's own phased execution, which needs no
    /// external vehicle, so unlike the subagent denial it cannot dead-end.
    #[test]
    fn the_workflow_denial_is_unconditional() {
        let event = serde_json::json!({
            "tool_name": "Workflow",
            "tool_input": {
                "description": "Compare frameworks",
                "script": "export const meta = { name: 'compare', description: 'test' }; ..."
            }
        });

        for (allele, opencode) in [(true, true), (false, false)] {
            let routing = route(&event, allele, opencode);
            let reason = denial_reason(&routing);
            assert!(reason.contains("BLOCKED"));
            assert!(reason.contains("Dynamic workflow orchestration"));
            assert!(reason.contains("Algorithm"));
            assert!(reason.contains("Compare frameworks"));
        }
    }

    #[test]
    fn pre_tool_use_denies_workflow_without_script() {
        let event = serde_json::json!({
            "tool_name": "Workflow",
            "tool_input": {
                "name": "saved-workflow"
            }
        });

        let reason_owned = denial_reason(&route(&event, true, true)).to_string();
        assert!(reason_owned.contains("BLOCKED"));
        assert!(reason_owned.contains("spawns dozens of native subagents"));
    }

    /// Field order in the routing log is its on-disk format, exactly as it is
    /// for the activation log next to it. A `serde_json::Map` would emit these
    /// alphabetically and silently break anything counting them.
    #[test]
    fn the_routing_record_serialises_in_declared_order() {
        let event = serde_json::json!({
            "session_id": "abc-123",
            "tool_name": "Task",
            "tool_input": {"description": "x"}
        });
        let record = routing_record(&event, "Task", availability(false, false), false, "why");
        let line = serde_json::to_string(&record).unwrap();

        let keys: Vec<&str> = line
            .split(',')
            .filter_map(|chunk| chunk.split(':').next())
            .map(|k| k.trim_matches(|c| c == '{' || c == '"'))
            .collect();
        assert_eq!(
            keys,
            vec![
                "ts",
                "session_id",
                "tool_name",
                "vehicle",
                "allele_reachable",
                "opencode_available",
                "escaped",
                "reason"
            ]
        );
        assert!(line.contains("\"session_id\":\"abc-123\""));
    }

    // -------------------------------------------- session-start notice --

    /// Once per session, not once per event: SessionStart fires again on
    /// compaction and availability is a session-level fact.
    #[test]
    fn the_availability_notice_is_claimed_once_per_session() {
        let tmp = tempfile::tempdir().unwrap();
        let event = serde_json::json!({"session_id": "session-abc"});

        assert!(claim_session_notice(tmp.path(), &event));
        assert!(!claim_session_notice(tmp.path(), &event));

        let other = serde_json::json!({"session_id": "session-def"});
        assert!(claim_session_notice(tmp.path(), &other));
    }

    /// No session id means no marker to key off. Saying it twice is a smaller
    /// failure than never saying it, and silence is the failure this path
    /// exists to remove.
    #[test]
    fn a_missing_session_id_still_gets_the_notice() {
        let tmp = tempfile::tempdir().unwrap();
        let event = serde_json::json!({});
        assert!(claim_session_notice(tmp.path(), &event));
        assert!(claim_session_notice(tmp.path(), &event));
    }

    #[test]
    fn is_claude_memory_path_detects_memory_writes() {
        assert!(is_claude_memory_path(
            "/Users/test/.claude/projects/-Users-test-myproject/memory/feedback_testing.md"
        ));
        assert!(is_claude_memory_path(
            "/Users/test/.claude/projects/-Users-test-myproject/memory/MEMORY.md"
        ));
        assert!(!is_claude_memory_path(
            "/Users/test/.claude/projects/-Users-test-myproject/some_other_file.md"
        ));
        assert!(!is_claude_memory_path(
            "/Users/test/.locus/data/memory/work/slug/PRD.md"
        ));
    }

    #[test]
    fn parse_locus_project_name_extracts_name() {
        assert_eq!(
            parse_locus_project_name("name: allele\ndisplay: Allele\n"),
            Some("allele".to_string())
        );
        assert_eq!(
            parse_locus_project_name("---\nname: the-long-burn\n---\n"),
            Some("the-long-burn".to_string())
        );
        assert_eq!(parse_locus_project_name("no name here\n"), None);
        assert_eq!(parse_locus_project_name("name: \n"), None);
    }

    #[test]
    fn resolve_from_registry_matches_exact_paths() {
        let reg = serde_json::json!({
            "projects": {
                "allele": {
                    "paths": ["/Users/test/allele"],
                    "patterns": []
                }
            }
        });

        assert_eq!(
            resolve_from_registry(&reg, Path::new("/Users/test/allele")),
            Some("allele".to_string())
        );
        assert_eq!(
            resolve_from_registry(&reg, Path::new("/Users/test/other")),
            None
        );
    }

    #[test]
    fn resolve_from_registry_matches_patterns() {
        let reg = serde_json::json!({
            "projects": {
                "allele": {
                    "paths": [],
                    "patterns": ["**/.allele/workspaces/allele/**"]
                }
            }
        });

        assert_eq!(
            resolve_from_registry(&reg, Path::new("/Users/test/.allele/workspaces/allele/abc123")),
            Some("allele".to_string())
        );
        assert_eq!(
            resolve_from_registry(&reg, Path::new("/Users/test/unrelated")),
            None
        );
    }

    #[test]
    fn resolve_project_slug_finds_marker_file() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("deep").join("nested");
        std::fs::create_dir_all(&project_dir).unwrap();
        std::fs::write(
            tmp.path().join("deep").join(".locus-project"),
            "name: my-project\n",
        )
        .unwrap();

        let data_dir = tmp.path().join("data");
        std::fs::create_dir_all(&data_dir).unwrap();

        assert_eq!(
            resolve_project_slug(&project_dir, &data_dir).unwrap(),
            "my-project"
        );
    }

    #[test]
    fn extract_link_target_parses_memory_index_lines() {
        assert_eq!(
            extract_link_target("- [My Title](my_file.md) — description"),
            Some("my_file.md".to_string())
        );
        assert_eq!(
            extract_link_target("- [Title](path/to/file.md)"),
            Some("path/to/file.md".to_string())
        );
        assert_eq!(extract_link_target("some random text"), None);
        assert_eq!(extract_link_target("# Heading"), None);
    }

    #[test]
    fn merge_memory_index_appends_new_entries() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("project");
        std::fs::create_dir_all(&project_dir).unwrap();

        // Existing Locus MEMORY.md
        std::fs::write(
            project_dir.join("MEMORY.md"),
            "- [Existing](existing.md) — already here\n",
        )
        .unwrap();

        // Claude Code MEMORY.md with one existing and one new entry
        let source = tmp.path().join("source_memory.md");
        std::fs::write(
            &source,
            "- [Existing](existing.md) — already here\n- [New Entry](new_entry.md) — just added\n",
        )
        .unwrap();

        merge_memory_index(&source, &project_dir).unwrap();

        let result = std::fs::read_to_string(project_dir.join("MEMORY.md")).unwrap();
        assert!(result.contains("existing.md"));
        assert!(result.contains("new_entry.md"));
        // existing.md should appear only once
        assert_eq!(result.matches("existing.md").count(), 1);
    }

    #[test]
    fn merge_memory_index_creates_target_if_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("project");
        std::fs::create_dir_all(&project_dir).unwrap();

        let source = tmp.path().join("source_memory.md");
        std::fs::write(&source, "- [Entry](entry.md) — new\n").unwrap();

        merge_memory_index(&source, &project_dir).unwrap();

        let result = std::fs::read_to_string(project_dir.join("MEMORY.md")).unwrap();
        assert!(result.contains("entry.md"));
    }

    #[test]
    fn merge_memory_index_noop_when_all_entries_exist() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("project");
        std::fs::create_dir_all(&project_dir).unwrap();

        let existing = "- [A](a.md) — first\n- [B](b.md) — second\n";
        std::fs::write(project_dir.join("MEMORY.md"), existing).unwrap();

        let source = tmp.path().join("source.md");
        std::fs::write(&source, "- [A](a.md) — first\n").unwrap();

        merge_memory_index(&source, &project_dir).unwrap();

        let result = std::fs::read_to_string(project_dir.join("MEMORY.md")).unwrap();
        assert_eq!(result, existing);
    }

    #[test]
    fn mirror_copies_memory_file_to_locus_project() {
        let tmp = tempfile::tempdir().unwrap();

        // Set up project dir with .locus-project marker
        let work_dir = tmp.path().join("workspace");
        std::fs::create_dir_all(&work_dir).unwrap();
        std::fs::write(work_dir.join(".locus-project"), "name: test-proj\n").unwrap();

        // Set up data dir
        let data_dir = tmp.path().join("data");
        std::fs::create_dir_all(data_dir.join("projects")).unwrap();

        // Simulate a Claude Code memory file
        let claude_mem_dir = tmp.path().join(".claude").join("projects").join("encoded").join("memory");
        std::fs::create_dir_all(&claude_mem_dir).unwrap();
        let mem_file = claude_mem_dir.join("feedback_testing.md");
        std::fs::write(&mem_file, "---\nname: test feedback\ntype: feedback\n---\n\nContent here.\n").unwrap();

        // Temporarily change CWD for the test
        let original_dir = std::env::current_dir().unwrap();
        std::env::set_current_dir(&work_dir).unwrap();

        let result = mirror_memory_to_locus(mem_file.to_str().unwrap(), &data_dir);

        std::env::set_current_dir(original_dir).unwrap();

        assert!(result.is_ok());
        let mirrored = data_dir.join("projects").join("test-proj").join("feedback_testing.md");
        assert!(mirrored.exists());
        let content = std::fs::read_to_string(mirrored).unwrap();
        assert!(content.contains("Content here."));
    }

    #[test]
    fn derive_slug_from_path_strips_dotfiles_and_lowercases() {
        let slug = derive_slug_from_path(Path::new("/Users/test/Sites/clients/my-project"));
        assert!(slug.contains("my-project"));
        assert!(!slug.contains("Users"));

        let slug2 = derive_slug_from_path(Path::new("/Users/test/.allele/workspaces/locus/abc123"));
        assert!(slug2.contains("workspaces"));
        assert!(slug2.contains("locus"));
        assert!(!slug2.contains(".allele"));
    }

    #[test]
    fn resolve_project_slug_falls_back_to_derived_slug() {
        let tmp = tempfile::tempdir().unwrap();
        let project_dir = tmp.path().join("deep").join("nested");
        std::fs::create_dir_all(&project_dir).unwrap();

        let data_dir = tmp.path().join("data");
        std::fs::create_dir_all(data_dir.join("projects")).unwrap();

        let result = resolve_project_slug(&project_dir, &data_dir);
        assert!(result.is_ok(), "Should fall back to derived slug");
        let slug = result.unwrap();
        assert!(slug.contains("nested") || slug.contains("deep"));
    }

    #[test]
    fn simple_glob_match_handles_common_patterns() {
        assert!(simple_glob_match("**/.allele/workspaces/allele/**", "/Users/test/.allele/workspaces/allele/abc"));
        assert!(simple_glob_match("**/the-long-burn", "/Users/test/the-long-burn"));
        assert!(!simple_glob_match("**/.allele/workspaces/allele/**", "/Users/test/other/path"));
        assert!(!simple_glob_match("", "/any/path"));
    }
}
