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
pub mod run;

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
        let native = config_gen::write_native_config(locus_home)?;

        Ok(SetupResult {
            agents_md_path: write_result.path,
            config_path,
            backed_up_agents_md: write_result.backed_up,
            native_agents_md_path: native.agents_md_path,
            native_config_path: native.config_path,
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
    /// Path to the generated AGENTS.md (algorithmic, global).
    pub agents_md_path: PathBuf,

    /// Path to the updated opencode.json (algorithmic, global).
    pub config_path: PathBuf,

    /// Whether an existing AGENTS.md was backed up.
    pub backed_up_agents_md: bool,

    /// Path to the native AGENTS.md (used when delegating with `--mode native`).
    pub native_agents_md_path: PathBuf,

    /// Path to the native opencode.json (used when delegating with `--mode native`).
    pub native_config_path: PathBuf,
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
    fn agents_md_lists_platform_tools() {
        // Use the deterministic helper so the test isn't sensitive to the
        // host's OPENCODE_ENABLE_EXA env state.
        let content =
            config_gen::generate_agents_md_with(Path::new("/home/test/.locus"), false);
        assert!(content.contains("Platform Tools (OpenCode)"));
        assert!(content.contains("web_fetch"));
        assert!(content.contains("bash"));
        assert!(content.contains("OPENCODE_ENABLE_EXA=1"));
    }

    #[test]
    fn agents_md_omits_web_search_when_env_unset() {
        let content =
            config_gen::generate_agents_md_with(Path::new("/home/test/.locus"), false);
        // The bullet line must not appear.
        assert!(!content.contains("- **web_search**"));
        // The negative caveat must appear.
        assert!(content.contains("`web_search` (open-ended web search) is NOT available"));
    }

    #[test]
    fn agents_md_lists_web_search_when_env_set() {
        let content =
            config_gen::generate_agents_md_with(Path::new("/home/test/.locus"), true);
        // The bullet line must appear.
        assert!(content.contains("- **web_search** (Exa)"));
        // The positive note must appear; the negative caveat must not.
        assert!(content.contains("`web_search` is available"));
        assert!(!content.contains("`web_search` (open-ended web search) is NOT available"));
    }

    #[test]
    fn native_agents_md_omits_algorithm_scaffolding() {
        let content = config_gen::generate_native_agents_md();
        // Forbidden hijacking imperatives — markers that would cause the
        // model to run the Algorithm in a delegated session. The word
        // "OBSERVE" may appear in negative guidance ("Do not run OBSERVE
        // ... phases"); what we forbid is the *imperative* form.
        assert!(!content.contains("Mode Classification (MANDATORY)"));
        assert!(!content.contains("Algorithm v1.1"));
        assert!(!content.contains("Follow the 7-phase structure"));
        assert!(!content.contains("Classification: Trivial"));
        assert!(!content.contains("Classification: Non-trivial"));
    }

    #[test]
    fn native_agents_md_frames_session_as_worker() {
        let content = config_gen::generate_native_agents_md();
        assert!(
            content.to_lowercase().contains("delegated worker")
                || content.to_lowercase().contains("worker spawned")
        );
        // Explicit "do not orchestrate" guidance.
        assert!(content.contains("Do not classify"));
        assert!(content.contains("Do not run OBSERVE"));
    }

    #[test]
    fn write_native_config_writes_both_files_under_xdg_path() {
        let tmp = tempfile::tempdir().unwrap();
        let result = config_gen::write_native_config(tmp.path()).unwrap();

        // Layout: <locus_home>/opencode-native-xdg/opencode/{AGENTS.md,opencode.json}
        let expected_dir = tmp.path().join("opencode-native-xdg").join("opencode");
        assert_eq!(result.agents_md_path, expected_dir.join("AGENTS.md"));
        assert_eq!(result.config_path, expected_dir.join("opencode.json"));
        assert!(result.agents_md_path.exists());
        assert!(result.config_path.exists());

        // opencode.json must NOT contain the `instructions` array.
        let json: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&result.config_path).unwrap()).unwrap();
        assert!(
            json.get("instructions").is_none(),
            "native opencode.json must not load Locus instructions"
        );
    }

    #[test]
    fn agents_md_does_not_contain_delegation_directive() {
        // OpenCode is the BACKEND for `locus delegate run`, not its caller.
        // This guards the asymmetry decision documented in config_gen.rs.
        let content = config_gen::generate_agents_md(Path::new("/home/test/.locus"));
        assert!(
            !content.contains("locus delegate run"),
            "AGENTS.md must not teach OpenCode to delegate to itself"
        );
        assert!(!content.contains("OpenCode Delegation"));
    }

    #[test]
    fn capabilities_lists_opencode_tools() {
        let adapter = OpenCodeAdapter::new();
        let caps = adapter.capabilities();
        assert!(caps.has_tool("glob"));
        assert!(caps.has_tool("grep"));
        assert!(caps.has_tool("read"));
        assert!(caps.has_tool("edit"));
        assert!(caps.has_tool("bash"));
        assert!(caps.has_tool("web_fetch"));
        assert!(caps.has_tool("task"));
    }

    #[test]
    fn capabilities_web_search_conditional_on_env() {
        let adapter = OpenCodeAdapter::new();
        let caps = adapter.capabilities();
        // Without OPENCODE_ENABLE_EXA set, web_search should not be present.
        let has_web_search = caps.has_tool("web_search");
        let env_set = std::env::var("OPENCODE_ENABLE_EXA")
            .is_ok_and(|v| !v.is_empty() && v != "0");
        assert_eq!(
            has_web_search, env_set,
            "web_search availability must match OPENCODE_ENABLE_EXA env var"
        );
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
        assert_eq!(config["permission"]["bash"].as_str(), Some("ask"));
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
