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
    /// with `instructions` entries. Returns paths of files that were modified.
    pub fn setup(&self, locus_home: &Path) -> Result<SetupResult, LocusError> {
        let agents_md_path = config_gen::write_agents_md(locus_home)?;
        let config_path = config_gen::update_opencode_json(locus_home)?;

        Ok(SetupResult {
            agents_md_path,
            config_path,
            backed_up_agents_md: false, // TODO: track this from write_agents_md
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
        assert!(content.contains("/home/test/.locus/algorithm/v1.0.md"));
        assert!(content.contains("/home/test/.locus/skills/"));
        assert!(content.contains("/home/test/.locus/agents/"));
        assert!(content.contains("MANDATORY"));
        assert!(content.contains("OBSERVE"));
        assert!(content.contains("VERIFY"));
        assert!(content.contains("LEARN"));
    }
}
