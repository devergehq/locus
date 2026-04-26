//! Claude Code platform adapter for Locus.
//!
//! The Claude Code adapter takes a minimal approach: Locus content stays
//! entirely in `~/.locus/`. The adapter only touches two files in Claude
//! Code's global config directory (`~/.claude/`):
//!
//! - `CLAUDE.md` — bootstrap with Algorithm inlined and pointers to `~/.locus/`
//! - `settings.json` — merged `hooks` entries calling `locus hook <event>`
//!
//! Zero files are written to `~/.claude/skills/` or `~/.claude/agents/`. The
//! Algorithm is the sole orchestration layer — skills and agents are loaded
//! by the Algorithm via the Read tool, not surfaced natively. This matches
//! the OpenCode adapter's philosophy.

pub mod capabilities;
pub mod config_gen;
pub mod events;

use locus_core::capabilities::CapabilityManifest;
use locus_core::error::LocusError;
use locus_core::platform::Platform;

use std::path::{Path, PathBuf};

/// Claude Code adapter.
pub struct ClaudeAdapter {
    capabilities: CapabilityManifest,
}

impl ClaudeAdapter {
    pub fn new() -> Self {
        Self {
            capabilities: capabilities::claude_capabilities(),
        }
    }

    pub fn platform(&self) -> Platform {
        Platform::ClaudeCode
    }

    pub fn capabilities(&self) -> &CapabilityManifest {
        &self.capabilities
    }

    /// Set up Locus for use with Claude Code.
    ///
    /// Writes `~/.claude/CLAUDE.md` (backing up any non-Locus existing file)
    /// and merges Locus hook entries into `~/.claude/settings.json`. Returns
    /// paths of files that were modified plus whether a backup occurred.
    pub fn setup(&self, locus_home: &Path) -> Result<SetupResult, LocusError> {
        let write_result = config_gen::write_claude_md(locus_home)?;
        let settings_path = config_gen::update_settings_json(locus_home)?;

        Ok(SetupResult {
            claude_md_path: write_result.path,
            settings_path,
            backed_up_claude_md: write_result.backed_up,
        })
    }
}

impl Default for ClaudeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

/// Result of setting up Locus for Claude Code.
pub struct SetupResult {
    /// Path to the generated CLAUDE.md.
    pub claude_md_path: PathBuf,

    /// Path to the updated settings.json.
    pub settings_path: PathBuf,

    /// Whether an existing non-Locus CLAUDE.md was backed up.
    pub backed_up_claude_md: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use locus_core::events::{HookEvent, LifecycleEvent};

    #[test]
    fn adapter_returns_correct_platform() {
        let adapter = ClaudeAdapter::new();
        assert_eq!(adapter.platform(), Platform::ClaudeCode);
    }

    #[test]
    fn capabilities_include_native_delegation() {
        let adapter = ClaudeAdapter::new();
        assert!(adapter.capabilities().has_native_delegation());
    }

    #[test]
    fn capabilities_include_session_events() {
        let adapter = ClaudeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.supports_lifecycle(&LifecycleEvent::SessionStart));
        assert!(caps.supports_lifecycle(&LifecycleEvent::SessionEnd));
        assert!(caps.supports_lifecycle(&LifecycleEvent::ContextCompact));
    }

    #[test]
    fn capabilities_exclude_suspend_resume() {
        let adapter = ClaudeAdapter::new();
        let caps = adapter.capabilities();
        assert!(!caps.supports_lifecycle(&LifecycleEvent::SessionSuspend));
        assert!(!caps.supports_lifecycle(&LifecycleEvent::SessionResume));
    }

    #[test]
    fn capabilities_include_tool_hooks() {
        let adapter = ClaudeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.supports_hook(&HookEvent::PreToolUse));
        assert!(caps.supports_hook(&HookEvent::PostToolUse));
        assert!(caps.supports_hook(&HookEvent::UserPromptSubmit));
        assert!(caps.supports_hook(&HookEvent::Notification));
    }

    #[test]
    fn capabilities_mcp_supported() {
        let adapter = ClaudeAdapter::new();
        assert!(adapter.capabilities().mcp_support);
    }

    #[test]
    fn claude_md_contains_locus_directive() {
        let content = config_gen::generate_claude_md(Path::new("/home/test/.locus"));
        assert!(content.contains("# Locus"));
        assert!(content.contains("/home/test/.locus/algorithm/v1.1.md"));
        assert!(content.contains("/home/test/.locus/skills/"));
        assert!(content.contains("/home/test/.locus/agents/"));
        assert!(content.contains("MANDATORY"));
        assert!(content.contains("OBSERVE"));
        assert!(content.contains("VERIFY"));
        assert!(content.contains("LEARN"));
    }

    #[test]
    fn claude_md_lists_platform_tools() {
        let content = config_gen::generate_claude_md(Path::new("/home/test/.locus"));
        assert!(content.contains("Platform Tools (Claude Code)"));
        assert!(content.contains("web_search"));
        assert!(content.contains("web_fetch"));
        assert!(content.contains("bash"));
    }

    #[test]
    fn claude_md_contains_delegation_section() {
        let content = config_gen::generate_claude_md(Path::new("/home/test/.locus"));
        assert!(content.contains("## Delegation Guardrail"));
        assert!(content.contains("## Locus Delegate"));
        assert!(content.contains("locus delegate run"));
        assert!(content.contains("--backend opencode"));
        assert!(content.contains("prohibited for Locus delegation"));
        assert!(content.contains("read-only"));
        assert!(content.contains("summary"));
        assert!(content.contains("findings"));
        assert!(content.contains("files_referenced"));
    }

    #[test]
    fn claude_md_documents_native_and_algorithmic_modes() {
        let content = config_gen::generate_claude_md(Path::new("/home/test/.locus"));
        // The invocation example must show the new --mode flag.
        assert!(
            content.contains("--mode native"),
            "delegation example must show --mode native"
        );
        // Both modes must be named so the reader knows the knob exists.
        assert!(
            content.contains("`--mode algorithmic`"),
            "must mention --mode algorithmic as the opt-in for the rare case"
        );
        // Must explain that native is the default (so the user understands
        // omitting --mode is safe).
        let lower = content.to_lowercase();
        assert!(
            lower.contains("native") && lower.contains("default"),
            "must state that native is the default mode"
        );
    }

    #[test]
    fn claude_md_delegation_lists_when_to_use() {
        let content = config_gen::generate_claude_md(Path::new("/home/test/.locus"));
        let section_start = content
            .find("## Locus Delegate")
            .expect("delegation section present");
        let section_end = content[section_start..]
            .find("## Platform Tools")
            .expect("section bounded by Platform Tools heading")
            + section_start;
        let section = &content[section_start..section_end];

        assert!(section.contains("**When to delegate:**"));
        assert!(section.contains("**When NOT to delegate:**"));
        assert!(section.contains("**Result envelope:**"));
        let when_to_bullets = section
            .split("**When to delegate:**")
            .nth(1)
            .and_then(|s| s.split("**When NOT to delegate:**").next())
            .unwrap_or("");
        let bullet_count = when_to_bullets
            .lines()
            .filter(|l| l.trim_start().starts_with("- "))
            .count();
        assert!(
            bullet_count >= 3,
            "expected at least 3 when-to bullets, got {}",
            bullet_count
        );
    }

    #[test]
    fn capabilities_lists_claude_tools() {
        let adapter = ClaudeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.has_tool("web_search"));
        assert!(caps.has_tool("web_fetch"));
        assert!(caps.has_tool("read"));
        assert!(caps.has_tool("edit"));
        assert!(caps.has_tool("bash"));
        assert!(caps.has_tool("task"));
        assert!(caps.has_tool("glob"));
        assert!(caps.has_tool("grep"));
    }

    #[test]
    fn settings_merge_preserves_non_locus_hooks() {
        let mut settings = serde_json::json!({
            "otherSetting": true,
            "hooks": {
                "SessionStart": [
                    {
                        "matcher": "",
                        "hooks": [
                            { "type": "command", "command": "user-owned-command" }
                        ]
                    }
                ],
                "UserDefinedHook": [
                    { "matcher": "", "hooks": [{ "type": "command", "command": "keep-me" }] }
                ]
            }
        });

        config_gen::merge_locus_hooks(&mut settings);

        // Non-hook root keys preserved.
        assert_eq!(settings.get("otherSetting"), Some(&serde_json::json!(true)));

        // User's hook group preserved.
        let ss = &settings["hooks"]["SessionStart"][0]["hooks"];
        let user_cmd = ss
            .as_array()
            .unwrap()
            .iter()
            .any(|h| h["command"] == "user-owned-command");
        assert!(user_cmd, "user's hook command must survive the merge");

        // Locus hook appended under the same matcher group.
        let locus_cmd = ss
            .as_array()
            .unwrap()
            .iter()
            .any(|h| h["command"] == "locus hook session-start");
        assert!(locus_cmd, "locus hook must be injected");

        // Non-Locus top-level hook key preserved intact.
        assert!(settings["hooks"]["UserDefinedHook"].is_array());
    }

    #[test]
    fn settings_merge_is_idempotent() {
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_hooks(&mut settings);
        let first = settings.clone();
        config_gen::merge_locus_hooks(&mut settings);
        assert_eq!(first, settings, "second merge must be a no-op");
    }

    #[test]
    fn settings_merge_writes_all_expected_hooks() {
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_hooks(&mut settings);
        let hooks = settings["hooks"].as_object().unwrap();
        for (name, _, _) in config_gen::locus_hook_entries() {
            assert!(hooks.contains_key(*name), "missing hook: {}", name);
        }
    }

    #[test]
    fn statusline_merge_sets_locus_script_when_absent() {
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_statusline(&mut settings, std::path::Path::new("/fake/.locus"));
        let sl = settings.get("statusLine").expect("statusLine set");
        assert_eq!(sl["type"], "command");
        assert!(sl["command"]
            .as_str()
            .unwrap()
            .ends_with("scripts/statusline.sh"));
    }

    #[test]
    fn statusline_merge_preserves_non_locus_statusline() {
        let mut settings = serde_json::json!({
            "statusLine": { "type": "command", "command": "/opt/custom/statusline.sh" }
        });
        config_gen::merge_locus_statusline(&mut settings, std::path::Path::new("/fake/.locus"));
        assert_eq!(
            settings["statusLine"]["command"].as_str().unwrap(),
            "/opt/custom/statusline.sh"
        );
    }

    #[test]
    fn statusline_merge_replaces_existing_locus_entry() {
        let mut settings = serde_json::json!({
            "statusLine": { "type": "command", "command": "/old/.locus/scripts/statusline.sh" }
        });
        config_gen::merge_locus_statusline(&mut settings, std::path::Path::new("/new/.locus"));
        assert!(settings["statusLine"]["command"]
            .as_str()
            .unwrap()
            .starts_with("/new/.locus/scripts/statusline.sh"));
    }

    #[test]
    fn permissions_merge_sets_allow_entries() {
        let locus_home = std::path::Path::new("/home/test/.locus");
        let locus_path = locus_home.display().to_string();
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        let allow = settings["permissions"]["allow"].as_array().unwrap();
        for entry in config_gen::locus_permission_entries(&locus_path) {
            assert!(
                allow.iter().any(|v| v.as_str() == Some(&entry)),
                "missing allow entry: {}",
                entry
            );
        }
    }

    #[test]
    fn permissions_merge_preserves_non_locus_allows() {
        let mut settings = serde_json::json!({
            "permissions": {
                "allow": ["Bash(npm run *)", "Read(/some/other/path/*)"]
            }
        });
        config_gen::merge_locus_permissions(
            &mut settings,
            std::path::Path::new("/home/test/.locus"),
        );
        let allow = settings["permissions"]["allow"].as_array().unwrap();
        assert!(
            allow.iter().any(|v| v.as_str() == Some("Bash(npm run *)")),
            "user-owned allow entry must survive the merge"
        );
        assert!(
            allow
                .iter()
                .any(|v| v.as_str() == Some("Read(/some/other/path/*)")),
            "user-owned read entry must survive the merge"
        );
    }

    #[test]
    fn permissions_merge_sets_additional_directories() {
        let locus_home = std::path::Path::new("/home/test/.locus");
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        let dirs = settings["permissions"]["additionalDirectories"]
            .as_array()
            .unwrap();
        assert!(
            dirs.iter().any(|v| v.as_str() == Some("/home/test/.locus")),
            "locus_home must be in additionalDirectories"
        );
    }

    #[test]
    fn permissions_merge_is_idempotent() {
        let locus_home = std::path::Path::new("/home/test/.locus");
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        let first = settings.clone();
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        assert_eq!(first, settings, "second permissions merge must be a no-op");
    }

    #[test]
    fn permissions_merge_sets_allele_allow_entries() {
        let locus_home = std::path::Path::new("/home/test/.locus");
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        let allow = settings["permissions"]["allow"].as_array().unwrap();

        let allele_entries: Vec<String> = allow
            .iter()
            .filter_map(|v| v.as_str())
            .filter(|s| s.contains(".allele"))
            .map(|s| s.to_string())
            .collect();

        assert!(!allele_entries.is_empty(), "allele entries must exist");
        assert!(
            allele_entries.iter().any(|s| s.starts_with("Read(")),
            "allele Read entry must exist"
        );
        assert!(
            allele_entries.iter().any(|s| s.starts_with("Write(")),
            "allele Write entry must exist"
        );
    }

    #[test]
    fn permissions_merge_sets_allele_additional_directories() {
        let locus_home = std::path::Path::new("/home/test/.locus");
        let mut settings = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut settings, locus_home);
        let dirs = settings["permissions"]["additionalDirectories"]
            .as_array()
            .unwrap();
        assert!(
            dirs.iter()
                .any(|v| v.as_str().map(|s| s.contains(".allele")).unwrap_or(false)),
            "allele home must be in additionalDirectories"
        );
    }

    #[test]
    fn event_mapping_round_trip() {
        let ss = events::map_lifecycle_event(&LifecycleEvent::SessionStart).unwrap();
        assert_eq!(ss.hook_name, "SessionStart");

        let cc = events::map_lifecycle_event(&LifecycleEvent::ContextCompact).unwrap();
        assert_eq!(cc.hook_name, "PreCompact");

        let pre = events::map_hook_event(&HookEvent::PreToolUse).unwrap();
        assert_eq!(pre.hook_name, "PreToolUse");

        let pfw = events::map_hook_event(&HookEvent::PreFileWrite).unwrap();
        assert_eq!(pfw.hook_name, "PreToolUse");
        assert_eq!(pfw.matcher, Some("Write|Edit"));

        assert!(events::map_lifecycle_event(&LifecycleEvent::SessionSuspend).is_none());
        assert!(events::map_lifecycle_event(&LifecycleEvent::SessionResume).is_none());
    }
}
