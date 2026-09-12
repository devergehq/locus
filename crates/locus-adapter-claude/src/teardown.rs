//! Teardown of the Claude Code configuration older Locus versions wrote.
//!
//! Locus used to generate `~/.claude/CLAUDE.md` and merge `locus hook *`
//! entries into `~/.claude/settings.json`. The plugin supplies both now, so
//! `locus platform remove claude-code` exists to undo the old writes.
//!
//! Two rules govern everything here, because this runs against a live config
//! directory the user also edits by hand:
//!
//! 1. **Ownership is proven from content, never from path.** A `CLAUDE.md` is
//!    ours only if it carries the `# Locus` marker; a hook is ours only if its
//!    command starts with `locus hook `. A hand-written `~/.claude/CLAUDE.md`
//!    is left exactly where it is.
//! 2. **Nothing else is touched.** `permissions.allow`, `statusLine`, and every
//!    non-Locus hook survive — a `tokenmaxer` hook sharing the `SessionStart`
//!    matcher group with a Locus hook keeps working.
//!
//! Removal is idempotent: containers are pruned only when this run emptied
//! them, so a second run finds nothing and writes nothing.

use std::path::{Path, PathBuf};

use locus_core::error::LocusError;
use locus_core::platform::Platform;

/// Marker identifying a `CLAUDE.md` that Locus generated.
pub const LOCUS_MARKER: &str = "# Locus";

/// Command prefix identifying a hook entry that Locus registered.
pub const LOCUS_HOOK_PREFIX: &str = "locus hook ";

/// One `settings.json` hook entry that was (or would be) removed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemovedHook {
    /// Hook event name, e.g. `SessionStart`.
    pub event: String,
    /// The matcher the entry sat under — empty string for the default group.
    pub matcher: String,
    /// The command that was removed, e.g. `locus hook session-start`.
    pub command: String,
}

/// What a teardown removed, or — under `--dry-run` — would remove.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Removal {
    /// The generated `CLAUDE.md` that was removed.
    pub claude_md: Option<PathBuf>,

    /// Where that `CLAUDE.md` was copied before removal.
    pub claude_md_backup: Option<PathBuf>,

    /// A `CLAUDE.md` exists but carries no Locus marker, so it was left alone.
    pub foreign_claude_md: Option<PathBuf>,

    /// Locus hook entries removed from `settings.json`.
    pub hooks: Vec<RemovedHook>,

    /// `settings.json`, when hook entries were removed from it.
    pub settings_path: Option<PathBuf>,

    /// `settings.json` exists but is not valid JSON, so it was left untouched.
    pub unparsable_settings: Option<PathBuf>,
}

impl Removal {
    /// Whether there was nothing Locus-owned left to remove.
    pub fn is_empty(&self) -> bool {
        self.claude_md.is_none() && self.hooks.is_empty()
    }
}

/// Remove every Locus-owned hook entry from a parsed `settings.json`.
///
/// Returns what was removed, in `settings.json` order. Matcher groups and hook
/// event keys are pruned only when this call emptied them, so a settings file
/// with a pre-existing empty group is not silently tidied — that would turn a
/// no-op run into a rewrite.
pub fn strip_locus_hooks(settings: &mut serde_json::Value) -> Vec<RemovedHook> {
    let mut removed = Vec::new();

    let Some(hooks) = settings.get_mut("hooks").and_then(|v| v.as_object_mut()) else {
        return removed;
    };

    let mut emptied_events = Vec::new();

    for (event, groups_value) in hooks.iter_mut() {
        let Some(groups) = groups_value.as_array_mut() else {
            continue;
        };

        let mut emptied_groups = Vec::new();
        let mut touched_event = false;

        for (idx, group) in groups.iter_mut().enumerate() {
            let matcher = group
                .get("matcher")
                .and_then(|m| m.as_str())
                .unwrap_or("")
                .to_string();

            let Some(entries) = group.get_mut("hooks").and_then(|v| v.as_array_mut()) else {
                continue;
            };

            let before = entries.len();
            entries.retain(|entry| {
                let command = entry
                    .get("command")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .trim_start();

                if command.starts_with(LOCUS_HOOK_PREFIX) {
                    removed.push(RemovedHook {
                        event: event.clone(),
                        matcher: matcher.clone(),
                        command: command.to_string(),
                    });
                    false
                } else {
                    true
                }
            });

            if entries.len() < before {
                touched_event = true;
                // Only a group *this run* emptied is pruned.
                if entries.is_empty() {
                    emptied_groups.push(idx);
                }
            }
        }

        for idx in emptied_groups.into_iter().rev() {
            groups.remove(idx);
        }

        if touched_event && groups.is_empty() {
            emptied_events.push(event.clone());
        }
    }

    for event in emptied_events {
        hooks.remove(&event);
    }

    // Drop a `hooks` object this run emptied, rather than leaving `"hooks": {}`.
    if !removed.is_empty() && hooks.is_empty() {
        settings
            .as_object_mut()
            .expect("settings is an object")
            .remove("hooks");
    }

    removed
}

/// Remove the Locus-owned Claude Code configuration under `config_dir`.
///
/// Touches exactly two things, and only when they are provably Locus-owned:
/// the generated `CLAUDE.md` (copied to `CLAUDE.md.backup` first) and
/// `locus hook *` entries in `settings.json`. `permissions.allow`, `statusLine`
/// and every non-Locus hook are left untouched.
///
/// With `dry_run` set, nothing is written — the returned [`Removal`] describes
/// what would happen.
pub fn remove_claude_config(config_dir: &Path, dry_run: bool) -> Result<Removal, LocusError> {
    let mut removal = Removal::default();

    // --- CLAUDE.md ---
    let claude_md = config_dir.join("CLAUDE.md");
    if claude_md.exists() {
        let content = std::fs::read_to_string(&claude_md).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read CLAUDE.md: {}", e),
            path: claude_md.clone(),
        })?;

        if content.contains(LOCUS_MARKER) {
            let backup = config_dir.join("CLAUDE.md.backup");

            if !dry_run {
                // Copy first and propagate the error — never delete 32KB of
                // generated content on the strength of a backup that failed.
                std::fs::copy(&claude_md, &backup).map_err(|e| LocusError::Filesystem {
                    message: format!("Failed to back up CLAUDE.md: {}", e),
                    path: backup.clone(),
                })?;
                std::fs::remove_file(&claude_md).map_err(|e| LocusError::Filesystem {
                    message: format!("Failed to remove CLAUDE.md: {}", e),
                    path: claude_md.clone(),
                })?;
            }

            removal.claude_md = Some(claude_md);
            removal.claude_md_backup = Some(backup);
        } else {
            removal.foreign_claude_md = Some(claude_md);
        }
    }

    // --- settings.json hook entries ---
    let settings_path = config_dir.join("settings.json");
    if settings_path.exists() {
        let content =
            std::fs::read_to_string(&settings_path).map_err(|e| LocusError::Filesystem {
                message: format!("Failed to read settings.json: {}", e),
                path: settings_path.clone(),
            })?;

        match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(mut settings) => {
                let removed = strip_locus_hooks(&mut settings);

                if !removed.is_empty() {
                    if !dry_run {
                        let rendered = serde_json::to_string_pretty(&settings).map_err(|e| {
                            LocusError::Adapter {
                                platform: Platform::ClaudeCode,
                                message: format!("Failed to serialise settings.json: {}", e),
                            }
                        })?;
                        std::fs::write(&settings_path, &rendered).map_err(|e| {
                            LocusError::Filesystem {
                                message: format!("Failed to write settings.json: {}", e),
                                path: settings_path.clone(),
                            }
                        })?;
                    }

                    removal.hooks = removed;
                    removal.settings_path = Some(settings_path);
                }
            }
            Err(_) => {
                // A malformed settings.json is hand-editable and recoverable.
                // Overwriting it with `{}` would not be.
                removal.unparsable_settings = Some(settings_path);
            }
        }
    }

    Ok(removal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    /// A settings.json shaped like Patrick's real one: seven `locus hook`
    /// entries, a `tokenmaxer` hook on SessionStart and SessionEnd, Locus
    /// permissions, and a Locus statusline.
    fn realistic_settings() -> serde_json::Value {
        serde_json::json!({
            "hooks": {
                "SessionStart": [{
                    "matcher": "",
                    "hooks": [
                        { "type": "command", "command": "locus hook session-start" },
                        { "type": "command", "command": "tokenmaxer hook session-start" }
                    ]
                }],
                "SessionEnd": [{
                    "matcher": "",
                    "hooks": [
                        { "type": "command", "command": "tokenmaxer hook session-end" }
                    ]
                }],
                "PreCompact": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook pre-compact" }]
                }],
                "Stop": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook stop" }]
                }],
                "UserPromptSubmit": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook user-prompt-submit" }]
                }],
                "PreToolUse": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook pre-tool-use" }]
                }],
                "PostToolUse": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook post-tool-use" }]
                }],
                "Notification": [{
                    "matcher": "",
                    "hooks": [{ "type": "command", "command": "locus hook notification" }]
                }]
            },
            "statusLine": {
                "type": "command",
                "command": "/Users/test/.locus/scripts/statusline.sh"
            },
            "permissions": {
                "allow": ["Read(/Users/test/.locus/**)", "Write(/Users/test/.locus/data/**)"],
                "additionalDirectories": ["/Users/test/.locus"]
            }
        })
    }

    /// Build a fixture config dir. `claude_md` is written verbatim when given.
    fn fixture(settings: Option<serde_json::Value>, claude_md: Option<&str>) -> TempDir {
        let dir = TempDir::new().unwrap();
        if let Some(settings) = settings {
            fs::write(
                dir.path().join("settings.json"),
                serde_json::to_string_pretty(&settings).unwrap(),
            )
            .unwrap();
        }
        if let Some(body) = claude_md {
            fs::write(dir.path().join("CLAUDE.md"), body).unwrap();
        }
        dir
    }

    fn settings_of(dir: &TempDir) -> serde_json::Value {
        serde_json::from_str(&fs::read_to_string(dir.path().join("settings.json")).unwrap())
            .unwrap()
    }

    fn commands_under(settings: &serde_json::Value, event: &str) -> Vec<String> {
        settings["hooks"][event]
            .as_array()
            .map(|groups| {
                groups
                    .iter()
                    .flat_map(|g| g["hooks"].as_array().cloned().unwrap_or_default())
                    .map(|h| h["command"].as_str().unwrap_or("").to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    // --- CLAUDE.md ---------------------------------------------------------

    #[test]
    fn removes_a_generated_claude_md() {
        let dir = fixture(
            None,
            Some("# Locus\n\nThis system uses the Locus framework.\n"),
        );
        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert!(!dir.path().join("CLAUDE.md").exists());
        assert_eq!(removal.claude_md, Some(dir.path().join("CLAUDE.md")));
    }

    #[test]
    fn backs_up_claude_md_before_removing_it() {
        let body = "# Locus\n\nGenerated directive.\n";
        let dir = fixture(None, Some(body));
        let removal = remove_claude_config(dir.path(), false).unwrap();

        let backup = dir.path().join("CLAUDE.md.backup");
        assert_eq!(removal.claude_md_backup, Some(backup.clone()));
        assert_eq!(fs::read_to_string(&backup).unwrap(), body);
    }

    #[test]
    fn leaves_a_hand_written_claude_md_alone() {
        let body = "# My own notes\n\nNothing to do with Locus.\n";
        let dir = fixture(None, Some(body));
        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            fs::read_to_string(dir.path().join("CLAUDE.md")).unwrap(),
            body
        );
        assert!(removal.claude_md.is_none());
        assert_eq!(
            removal.foreign_claude_md,
            Some(dir.path().join("CLAUDE.md"))
        );
        assert!(!dir.path().join("CLAUDE.md.backup").exists());
    }

    // --- settings.json hook surgery ---------------------------------------

    #[test]
    fn removes_every_locus_hook_entry() {
        let dir = fixture(Some(realistic_settings()), None);
        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(removal.hooks.len(), 7, "seven locus hook entries expected");

        let after = fs::read_to_string(dir.path().join("settings.json")).unwrap();
        assert!(
            !after.contains("locus hook "),
            "no locus hook entry may survive:\n{after}"
        );
    }

    #[test]
    fn preserves_tokenmaxer_sharing_the_session_start_group() {
        let dir = fixture(Some(realistic_settings()), None);
        remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            commands_under(&settings_of(&dir), "SessionStart"),
            vec!["tokenmaxer hook session-start"]
        );
    }

    #[test]
    fn preserves_tokenmaxer_on_session_end() {
        let dir = fixture(Some(realistic_settings()), None);
        remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            commands_under(&settings_of(&dir), "SessionEnd"),
            vec!["tokenmaxer hook session-end"]
        );
    }

    #[test]
    fn prunes_groups_and_events_it_empties() {
        let dir = fixture(Some(realistic_settings()), None);
        remove_claude_config(dir.path(), false).unwrap();

        let after = settings_of(&dir);
        let hooks = after["hooks"].as_object().unwrap();

        // Locus-only events are gone entirely, not left as empty arrays.
        for event in [
            "PreCompact",
            "Stop",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Notification",
        ] {
            assert!(
                !hooks.contains_key(event),
                "{event} should have been pruned"
            );
        }
        // Shared / third-party events remain.
        assert!(hooks.contains_key("SessionStart"));
        assert!(hooks.contains_key("SessionEnd"));
    }

    #[test]
    fn leaves_a_pre_existing_empty_group_alone() {
        // A group that was already empty is not ours to tidy — tidying it would
        // turn a no-op second run into a rewrite.
        let settings = serde_json::json!({
            "hooks": { "SessionStart": [{ "matcher": "", "hooks": [] }] }
        });
        let dir = fixture(Some(settings), None);
        let before = fs::read_to_string(dir.path().join("settings.json")).unwrap();

        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert!(removal.is_empty());
        assert_eq!(
            fs::read_to_string(dir.path().join("settings.json")).unwrap(),
            before
        );
    }

    // --- what must survive -------------------------------------------------

    #[test]
    fn leaves_permissions_allow_untouched() {
        let dir = fixture(Some(realistic_settings()), None);
        remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            settings_of(&dir)["permissions"],
            realistic_settings()["permissions"]
        );
    }

    #[test]
    fn leaves_a_locus_statusline_untouched() {
        let dir = fixture(Some(realistic_settings()), None);
        remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            settings_of(&dir)["statusLine"],
            realistic_settings()["statusLine"]
        );
    }

    #[test]
    fn leaves_a_non_locus_statusline_untouched() {
        let mut settings = realistic_settings();
        settings["statusLine"] = serde_json::json!({
            "type": "command",
            "command": "~/bin/my-own-statusline"
        });
        let dir = fixture(Some(settings.clone()), None);

        remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(settings_of(&dir)["statusLine"], settings["statusLine"]);
    }

    // --- idempotence -------------------------------------------------------

    #[test]
    fn second_run_removes_nothing() {
        let dir = fixture(Some(realistic_settings()), Some("# Locus\n\nDirective.\n"));

        let first = remove_claude_config(dir.path(), false).unwrap();
        assert!(!first.is_empty());

        let after_first = fs::read_to_string(dir.path().join("settings.json")).unwrap();
        let second = remove_claude_config(dir.path(), false).unwrap();

        assert!(second.is_empty(), "second run found work to do: {second:?}");
        assert_eq!(second.hooks.len(), 0);
        assert_eq!(
            fs::read_to_string(dir.path().join("settings.json")).unwrap(),
            after_first,
            "second run rewrote settings.json"
        );
    }

    #[test]
    fn removal_on_an_untouched_config_dir_is_a_no_op() {
        let dir = TempDir::new().unwrap();
        let removal = remove_claude_config(dir.path(), false).unwrap();
        assert!(removal.is_empty());
    }

    // --- dry run -----------------------------------------------------------

    #[test]
    fn dry_run_leaves_settings_json_byte_identical() {
        let dir = fixture(Some(realistic_settings()), None);
        let before = fs::read_to_string(dir.path().join("settings.json")).unwrap();

        let removal = remove_claude_config(dir.path(), true).unwrap();

        assert_eq!(removal.hooks.len(), 7, "dry run still reports the plan");
        assert_eq!(
            fs::read_to_string(dir.path().join("settings.json")).unwrap(),
            before
        );
    }

    #[test]
    fn dry_run_leaves_claude_md_byte_identical() {
        let body = "# Locus\n\nDirective.\n";
        let dir = fixture(None, Some(body));

        let removal = remove_claude_config(dir.path(), true).unwrap();

        assert_eq!(removal.claude_md, Some(dir.path().join("CLAUDE.md")));
        assert_eq!(
            fs::read_to_string(dir.path().join("CLAUDE.md")).unwrap(),
            body
        );
        assert!(!dir.path().join("CLAUDE.md.backup").exists());
    }

    // --- hostile input -----------------------------------------------------

    #[test]
    fn malformed_settings_json_is_reported_not_overwritten() {
        let dir = TempDir::new().unwrap();
        let broken = "{ \"hooks\": { oops";
        fs::write(dir.path().join("settings.json"), broken).unwrap();

        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(
            removal.unparsable_settings,
            Some(dir.path().join("settings.json"))
        );
        assert_eq!(
            fs::read_to_string(dir.path().join("settings.json")).unwrap(),
            broken,
            "a recoverable hand-editable file must not be clobbered"
        );
    }

    #[test]
    fn tolerates_hook_shapes_it_does_not_recognise() {
        let settings = serde_json::json!({
            "hooks": {
                "SessionStart": "not-an-array",
                "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "locus hook stop" }] }],
                "Weird": [42]
            }
        });
        let dir = fixture(Some(settings), None);

        let removal = remove_claude_config(dir.path(), false).unwrap();

        assert_eq!(removal.hooks.len(), 1);
        let after = settings_of(&dir);
        assert_eq!(after["hooks"]["SessionStart"], "not-an-array");
        assert_eq!(after["hooks"]["Weird"], serde_json::json!([42]));
    }

    #[test]
    fn matches_a_locus_hook_with_leading_whitespace() {
        let settings = serde_json::json!({
            "hooks": {
                "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "  locus hook stop" }] }]
            }
        });
        let dir = fixture(Some(settings), None);

        let removal = remove_claude_config(dir.path(), false).unwrap();
        assert_eq!(removal.hooks.len(), 1);
    }

    #[test]
    fn records_the_event_and_command_of_each_removal() {
        let dir = fixture(Some(realistic_settings()), None);
        let removal = remove_claude_config(dir.path(), true).unwrap();

        let mut described: Vec<String> = removal
            .hooks
            .iter()
            .map(|h| format!("{}:{}", h.event, h.command))
            .collect();
        described.sort();

        assert_eq!(
            described,
            vec![
                "Notification:locus hook notification",
                "PostToolUse:locus hook post-tool-use",
                "PreCompact:locus hook pre-compact",
                "PreToolUse:locus hook pre-tool-use",
                "SessionStart:locus hook session-start",
                "Stop:locus hook stop",
                "UserPromptSubmit:locus hook user-prompt-submit",
            ]
        );
    }
}
