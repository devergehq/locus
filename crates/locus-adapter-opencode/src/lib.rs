//! OpenCode platform adapter for Locus.
//!
//! The OpenCode adapter takes a minimal approach: Locus content stays
//! entirely in `~/.locus/`. The adapter only touches two files in
//! OpenCode's global config directory (`~/.config/opencode/`):
//!
//! - `AGENTS.md` — thin bootstrap (~10 lines) telling the AI about Locus
//! - `opencode.json` — `instructions` array pointing at Locus's algorithm and protocols
//!
//! Zero files are written to `.opencode/`. The Algorithm is the sole
//! orchestration layer — OpenCode's native skill/agent system is not used.

pub mod capabilities;
pub mod config_gen;
pub mod events;

use locus_core::capabilities::CapabilityManifest;
use locus_core::error::LocusError;
use locus_core::platform::Platform;

use std::path::{Path, PathBuf};

/// OpenCode adapter.
pub struct OpenCodeAdapter {
    capabilities: CapabilityManifest,
}

impl OpenCodeAdapter {
    pub fn new() -> Self {
        Self {
            capabilities: capabilities::opencode_capabilities(),
        }
    }

    pub fn platform(&self) -> Platform {
        Platform::OpenCode
    }

    pub fn capabilities(&self) -> &CapabilityManifest {
        &self.capabilities
    }

    /// Set up Locus for use with OpenCode.
    ///
    /// Writes the thin AGENTS.md bootstrap and updates opencode.json
    /// with `instructions` entries. Returns paths of files that were modified
    /// along with whether any pre-existing file was backed up.
    pub fn setup(&self, locus_home: &Path) -> Result<SetupResult, LocusError> {
        let write_result = config_gen::write_agents_md(locus_home)?;
        let config_path = config_gen::update_opencode_json(locus_home)?;

        Ok(SetupResult {
            agents_md_path: write_result.path,
            config_path,
            backed_up_agents_md: write_result.backed_up,
        })
    }
}

impl Default for OpenCodeAdapter {
    fn default() -> Self {
        Self::new()
    }
}

/// Result of setting up Locus for OpenCode.
pub struct SetupResult {
    /// Path to the generated AGENTS.md.
    pub agents_md_path: PathBuf,

    /// Path to the updated opencode.json.
    pub config_path: PathBuf,

    /// Whether an existing AGENTS.md was backed up.
    pub backed_up_agents_md: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapter_returns_correct_platform() {
        let adapter = OpenCodeAdapter::new();
        assert_eq!(adapter.platform(), Platform::OpenCode);
    }

    #[test]
    fn capabilities_include_native_delegation() {
        let adapter = OpenCodeAdapter::new();
        assert!(adapter.capabilities().has_native_delegation());
    }

    #[test]
    fn capabilities_include_session_events() {
        let adapter = OpenCodeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.supports_lifecycle(&locus_core::events::LifecycleEvent::SessionStart));
        assert!(caps.supports_lifecycle(&locus_core::events::LifecycleEvent::SessionEnd));
        assert!(caps.supports_lifecycle(&locus_core::events::LifecycleEvent::ContextCompact));
    }

    #[test]
    fn capabilities_exclude_suspend_resume() {
        let adapter = OpenCodeAdapter::new();
        let caps = adapter.capabilities();
        assert!(!caps.supports_lifecycle(&locus_core::events::LifecycleEvent::SessionSuspend));
        assert!(!caps.supports_lifecycle(&locus_core::events::LifecycleEvent::SessionResume));
    }

    #[test]
    fn capabilities_include_tool_hooks() {
        let adapter = OpenCodeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.supports_hook(&locus_core::events::HookEvent::PreToolUse));
        assert!(caps.supports_hook(&locus_core::events::HookEvent::PostToolUse));
    }

    #[test]
    fn capabilities_mcp_supported() {
        let adapter = OpenCodeAdapter::new();
        assert!(adapter.capabilities().mcp_support);
    }

    #[test]
    fn agents_md_contains_locus_directive() {
        let content = config_gen::generate_agents_md(Path::new("/home/test/.locus"));
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
    fn permissions_merge_sets_read_on_whole_locus() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, locus_home);

        let read = config["permission"]["read"].as_object().unwrap();
        assert_eq!(
            read.get("/home/test/.locus/**"),
            Some(&serde_json::json!("allow"))
        );
        // Read should cover the whole locus home, not just data.
        assert!(!read.contains_key("/home/test/.locus/data/**"));
    }

    #[test]
    fn permissions_merge_sets_edit_only_on_data() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, locus_home);

        let edit = config["permission"]["edit"].as_object().unwrap();
        assert_eq!(
            edit.get("/home/test/.locus/data/**"),
            Some(&serde_json::json!("allow"))
        );
        // Edit should NOT cover the whole locus home.
        assert!(!edit.contains_key("/home/test/.locus/**"));
    }

    #[test]
    fn permissions_merge_preserves_non_locus_entries() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({
            "permission": {
                "read": {
                    "/some/other/path/**": "allow"
                },
                "bash": "ask"
            }
        });
        config_gen::merge_locus_permissions(&mut config, locus_home);

        let read = config["permission"]["read"].as_object().unwrap();
        assert_eq!(
            read.get("/some/other/path/**"),
            Some(&serde_json::json!("allow"))
        );
        assert_eq!(
            read.get("/home/test/.locus/**"),
            Some(&serde_json::json!("allow"))
        );
        assert_eq!(
            config["permission"]["bash"].as_str(),
            Some("ask")
        );
    }

    #[test]
    fn permissions_merge_is_idempotent() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, locus_home);
        let first = config.clone();
        config_gen::merge_locus_permissions(&mut config, locus_home);
        assert_eq!(first, config, "second permissions merge must be a no-op");
    }

    #[test]
    fn permissions_merge_updates_on_locus_home_change() {
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, Path::new("/old/.locus"));
        config_gen::merge_locus_permissions(&mut config, Path::new("/new/.locus"));

        let read = config["permission"]["read"].as_object().unwrap();
        assert!(!read.contains_key("/old/.locus/**"));
        assert_eq!(
            read.get("/new/.locus/**"),
            Some(&serde_json::json!("allow"))
        );

        let edit = config["permission"]["edit"].as_object().unwrap();
        assert!(!edit.contains_key("/old/.locus/data/**"));
        assert_eq!(
            edit.get("/new/.locus/data/**"),
            Some(&serde_json::json!("allow"))
        );
    }

    #[test]
    fn permissions_merge_sets_read_and_edit_on_allele() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, locus_home);

        let read = config["permission"]["read"].as_object().unwrap();
        let edit = config["permission"]["edit"].as_object().unwrap();

        let read_key = read
            .keys()
            .find(|k| k.contains(".allele"))
            .expect("allele read key exists");
        assert!(read_key.ends_with("/**"));
        assert_eq!(read.get(read_key), Some(&serde_json::json!("allow")));

        let edit_key = edit
            .keys()
            .find(|k| k.contains(".allele"))
            .expect("allele edit key exists");
        assert!(edit_key.ends_with("/**"));
        assert_eq!(edit.get(edit_key), Some(&serde_json::json!("allow")));
    }

    #[test]
    fn permissions_merge_is_idempotent_for_allele() {
        let locus_home = Path::new("/home/test/.locus");
        let mut config = serde_json::json!({});
        config_gen::merge_locus_permissions(&mut config, locus_home);
        let first = config.clone();
        config_gen::merge_locus_permissions(&mut config, locus_home);
        assert_eq!(
            first, config,
            "second permissions merge must be a no-op for allele entries"
        );
    }
}
