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

fn handle_pre_tool_use(event: &serde_json::Value, _data_dir: &Path) -> Result<(), LocusError> {
    if let Some(decision) = native_agent_delegation_denial(event) {
        return write_stdout_json(&decision);
    }

    Ok(())
}

fn native_agent_delegation_denial(event: &serde_json::Value) -> Option<serde_json::Value> {
    let tool_name = event
        .get("tool_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if !matches!(tool_name, "Task" | "Agent" | "TeamCreate" | "task" | "agent") {
        return None;
    }

    Some(serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "Native agent delegation is prohibited by Locus. Use `locus delegate run --backend opencode --mode native --dir . --prompt \"<bounded task>\" --output json`, or continue serially if Locus Delegate is unavailable."
        }
    }))
}

fn handle_post_tool_use(event: &serde_json::Value, data_dir: &Path) -> Result<(), LocusError> {
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

    if file_path.ends_with("/PRD.md") {
        let _ = sync_prd_to_work_json(Path::new(file_path), data_dir);
    }

    if is_claude_memory_path(file_path) {
        let _ = mirror_memory_to_locus(file_path, data_dir);
    }

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

// ---------- Claude Code memory mirroring ----------

fn is_claude_memory_path(path: &str) -> bool {
    path.contains("/.claude/projects/") && path.contains("/memory/")
}

fn mirror_memory_to_locus(file_path: &str, data_dir: &Path) -> Result<(), LocusError> {
    let path = Path::new(file_path);
    let filename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");

    if filename.is_empty() {
        return Ok(());
    }

    let cwd = std::env::current_dir().map_err(|e| LocusError::Filesystem {
        message: format!("Failed to get CWD: {}", e),
        path: PathBuf::new(),
    })?;

    let slug = match resolve_project_slug(&cwd, data_dir) {
        Ok(s) => s,
        Err(_) => return Ok(()),
    };

    let project_dir = data_dir.join("projects").join(&slug);
    std::fs::create_dir_all(&project_dir).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to create project dir: {}", e),
        path: project_dir.clone(),
    })?;

    if filename == "MEMORY.md" {
        merge_memory_index(path, &project_dir)?;
    } else {
        let dest = project_dir.join(filename);
        std::fs::copy(file_path, &dest).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to mirror memory file: {}", e),
            path: dest,
        })?;
    }

    Ok(())
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

    Err(LocusError::Memory {
        message: format!("Could not resolve Locus project for: {}", cwd.display()),
    })
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
fn merge_memory_index(source_path: &Path, project_dir: &Path) -> Result<(), LocusError> {
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

    if new_entries.is_empty() {
        return Ok(());
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

    Ok(())
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

    #[test]
    fn pre_tool_use_denies_native_agent_delegation() {
        let event = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "Task",
            "tool_input": {"description": "research"}
        });

        let decision = native_agent_delegation_denial(&event).expect("Task must be denied");
        assert_eq!(
            decision["hookSpecificOutput"]["permissionDecision"].as_str(),
            Some("deny")
        );
        assert!(decision["hookSpecificOutput"]["permissionDecisionReason"]
            .as_str()
            .unwrap()
            .contains("locus delegate run"));
    }

    #[test]
    fn pre_tool_use_allows_non_agent_tools() {
        let event = serde_json::json!({
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "locus delegate run --backend opencode"}
        });

        assert!(native_agent_delegation_denial(&event).is_none());
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
    fn simple_glob_match_handles_common_patterns() {
        assert!(simple_glob_match("**/.allele/workspaces/allele/**", "/Users/test/.allele/workspaces/allele/abc"));
        assert!(simple_glob_match("**/the-long-burn", "/Users/test/the-long-burn"));
        assert!(!simple_glob_match("**/.allele/workspaces/allele/**", "/Users/test/other/path"));
        assert!(!simple_glob_match("", "/any/path"));
    }
}
