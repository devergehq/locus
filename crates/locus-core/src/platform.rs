//! Supported AI coding platforms.
//!
//! The [`Platform`] enum is exhaustive — adding a new platform variant
//! causes compiler errors everywhere it isn't handled, ensuring every
//! adapter, config generator, and capability check is updated.

use serde::{Deserialize, Serialize};
use std::fmt;

/// A supported AI coding platform that Locus can target via an adapter.
///
/// Adding a variant here will produce compile errors in every `match`
/// across the codebase — this is intentional. It ensures no platform
/// goes unhandled in adapter logic, config generation, or capability checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum Platform {
    /// Claude Code — Anthropic's CLI coding agent.
    /// Rich hooks (7 events), Task tool with subagent delegation,
    /// CLAUDE.md system prompt, MCP server support.
    ClaudeCode,

    /// OpenCode — open-source AI coding CLI.
    /// Plugin API (~16 events), AGENTS.md, opencode.json config.
    OpenCode,
}

impl Platform {
    /// Returns the conventional config directory name for this platform.
    ///
    /// Used to detect whether a platform is installed by checking
    /// for this directory in the user's home.
    pub fn config_dir_name(&self) -> &'static str {
        match self {
            Self::ClaudeCode => ".claude",
            Self::OpenCode => ".opencode",
        }
    }

    /// Returns a human-readable display name.
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::OpenCode => "OpenCode",
        }
    }

    /// Returns the CLI command used to invoke this platform.
    pub fn cli_command(&self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude",
            Self::OpenCode => "opencode",
        }
    }

    /// Returns all known platforms.
    pub fn all() -> &'static [Platform] {
        &[Self::ClaudeCode, Self::OpenCode]
    }
}

impl fmt::Display for Platform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.display_name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_platforms_have_config_dirs() {
        for platform in Platform::all() {
            assert!(!platform.config_dir_name().is_empty());
        }
    }

    #[test]
    fn all_platforms_have_cli_commands() {
        for platform in Platform::all() {
            assert!(!platform.cli_command().is_empty());
        }
    }

    #[test]
    fn serde_roundtrip() {
        let json = serde_json::to_string(&Platform::ClaudeCode).unwrap();
        assert_eq!(json, "\"claude-code\"");

        let parsed: Platform = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, Platform::ClaudeCode);
    }

    #[test]
    fn serde_opencode() {
        let json = serde_json::to_string(&Platform::OpenCode).unwrap();
        assert_eq!(json, "\"open-code\"");

        let parsed: Platform = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, Platform::OpenCode);
    }
}
