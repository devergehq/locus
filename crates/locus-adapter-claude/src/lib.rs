//! Claude Code platform adapter for Locus.
//!
//! Locus content stays entirely in `~/.locus/`. The Claude Code **plugin**
//! (see `.claude-plugin/`) supplies the directive and the hooks, so this
//! adapter no longer generates `~/.claude/CLAUDE.md` and no longer registers
//! `locus hook *` entries in `settings.json`.
//!
//! What it still writes is what a plugin manifest cannot express —
//! `statusLine` and `permissions.allow` are `settings.json` fields with no
//! manifest equivalent. See [`config_gen`].
//!
//! [`teardown`] undoes what older versions wrote, for
//! `locus platform remove claude-code`.

pub mod capabilities;
pub mod config_gen;
pub mod events;
pub mod teardown;

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
    /// Writes `statusLine` and `permissions.allow` into
    /// `~/.claude/settings.json` and nothing else. No `CLAUDE.md` is generated
    /// and no hook entries are registered — the plugin owns both.
    pub fn setup(&self, locus_home: &Path) -> Result<SetupResult, LocusError> {
        let settings_path = config_gen::write_locus_settings(locus_home)?;

        Ok(SetupResult { settings_path })
    }

    /// Remove the Locus-owned Claude Code configuration older versions wrote.
    ///
    /// Touches only the generated `~/.claude/CLAUDE.md` (and only when it
    /// carries the `# Locus` marker) and `locus hook *` entries in
    /// `settings.json`. Permissions, the statusline and every non-Locus hook
    /// survive. With `dry_run`, nothing is written.
    pub fn teardown(&self, dry_run: bool) -> Result<teardown::Removal, LocusError> {
        let config_dir = config_gen::global_config_dir()?;
        if !config_dir.exists() {
            return Ok(teardown::Removal::default());
        }
        teardown::remove_claude_config(&config_dir, dry_run)
    }
}

impl Default for ClaudeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

/// Result of setting up Locus for Claude Code.
pub struct SetupResult {
    /// Path to the updated settings.json.
    pub settings_path: PathBuf,
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
