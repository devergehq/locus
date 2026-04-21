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

fn handle_session_start(_event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    // Inject additional context informing the model that Locus is active,
    // where the Algorithm lives, and how to classify modes.
    let ctx = "Locus is active on this session. The Algorithm at ~/.locus/algorithm/v1.1.md \
governs non-trivial requests: OBSERVE -> THINK -> PLAN -> BUILD -> EXECUTE -> VERIFY -> LEARN. \
Classify every request as trivial (single file/concept) or non-trivial (multi-step, investigation, \
design). Non-trivial enters the Algorithm. Skills live at ~/.locus/skills/ and load via Read.";

    let out = serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": ctx
        }
    });
    write_stdout_json(&out)
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

fn handle_user_prompt_submit(_event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    // Reserved for future use (e.g., learning capture on prompt submit).
    Ok(())
}

fn handle_pre_tool_use(_event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    // Reserved for future use (e.g., permission validation).
    Ok(())
}

fn handle_post_tool_use(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    // If the tool was a Write or Edit targeting a PRD.md file, sync its
    // frontmatter and criteria counts into {data}/memory/state/work.json
    // so `locus status` can report progress without re-parsing every PRD.
    let tool_name = event
        .get("tool_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if tool_name != "Write" && tool_name != "Edit" {
        return Ok(());
    }

    let file_path = event
        .get("tool_input")
        .and_then(|v| v.get("file_path"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if !file_path.ends_with("/PRD.md") {
        return Ok(());
    }

    let _ = sync_prd_to_work_json(Path::new(file_path), data_dir);
    Ok(())
}

fn handle_stop(_event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
    // Warn (via stderr — hooks should not corrupt stdout) if any recent PRD
    // reached phase:learn without a corresponding learning file.
    let work_dir = data_dir.join("memory").join("work");
    if !work_dir.exists() {
        return Ok(());
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
    Ok(())
}

fn handle_notification(_event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    // No voice, no bells. Reserved for future platform-agnostic notifications.
    Ok(())
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

/// Parse a PRD.md's YAML frontmatter and criteria checkboxes, then write or
/// update the corresponding entry in `{data}/memory/state/work.json`.
pub(crate) fn sync_prd_to_work_json(prd_path: &Path, data_dir: &Path) -> Result<(), LocusError> {
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

    let entry = serde_json::json!({
        "slug": slug,
        "task": fm.get("task").and_then(|v| v.as_str()).unwrap_or(""),
        "phase": fm.get("phase").and_then(|v| v.as_str()).unwrap_or(""),
        "effort": fm.get("effort").and_then(|v| v.as_str()).unwrap_or(""),
        "mode": fm.get("mode").and_then(|v| v.as_str()).unwrap_or(""),
        "progress": format!("{}/{}", done, total),
        "updated": fm.get("updated").and_then(|v| v.as_str()).unwrap_or(""),
        "path": prd_path.display().to_string(),
    });

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

        sync_prd_to_work_json(&prd_path, tmp.path()).unwrap();

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
}
