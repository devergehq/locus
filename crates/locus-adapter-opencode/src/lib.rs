//! OpenCode platform adapter for Locus.
//!
//! Translates Locus's internal model to OpenCode's plugin system,
//! configuration format, and event model.
//!
//! # Generated Files
//!
//! When `generate_config` is called, this adapter produces:
//!
//! - `opencode.json` — OpenCode runtime config (model routing, permissions)
//! - `AGENTS.md` — System prompt with Locus algorithm, skill listing, protocols
//! - `.opencode/agents/*.md` — Individual agent definitions in PascalCase

pub mod capabilities;
pub mod config_gen;
pub mod events;

use locus_core::adapter::{GeneratedFile, LocusPaths};
use locus_core::capabilities::CapabilityManifest;
use locus_core::config::LocusConfig;
use locus_core::error::LocusError;
use locus_core::platform::Platform;

/// OpenCode adapter — generates platform-specific configuration from Locus config.
pub struct OpenCodeAdapter {
    capabilities: CapabilityManifest,
}

impl OpenCodeAdapter {
    pub fn new() -> Self {
        Self {
            capabilities: capabilities::opencode_capabilities(),
        }
    }

    /// Get the platform this adapter targets.
    pub fn platform(&self) -> Platform {
        Platform::OpenCode
    }

    /// Get the capability manifest.
    pub fn capabilities(&self) -> &CapabilityManifest {
        &self.capabilities
    }

    /// Resolve Locus paths for the OpenCode platform.
    pub fn resolve_paths(&self, config: &LocusConfig) -> Result<LocusPaths, LocusError> {
        let home = config.resolve_home()?;
        let data = config.resolve_data_dir()?;

        let platform_config = dirs::home_dir()
            .map(|h| h.join(".opencode"))
            .ok_or_else(|| LocusError::Adapter {
                platform: Platform::OpenCode,
                message: "Could not determine home directory".into(),
            })?;

        Ok(LocusPaths {
            config: home.join("locus.yaml"),
            algorithm: home.join("algorithm"),
            skills: home.join("skills"),
            agents: home.join("agents"),
            protocols: home.join("protocols"),
            home,
            data,
            platform_config,
        })
    }

    /// Generate OpenCode configuration files from Locus config.
    ///
    /// Returns a list of files to write. The caller decides where to write them
    /// (typically the current project directory or the OpenCode config directory).
    pub fn generate_config(
        &self,
        config: &LocusConfig,
    ) -> Result<Vec<GeneratedFile>, LocusError> {
        let home = config.resolve_home()?;
        config_gen::generate_opencode_config(config, &home)
    }
}

impl Default for OpenCodeAdapter {
    fn default() -> Self {
        Self::new()
    }
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
}
