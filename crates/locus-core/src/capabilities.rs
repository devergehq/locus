//! Platform capability negotiation.
//!
//! Each platform adapter declares what it supports via a [`CapabilityManifest`].
//! Locus core queries this manifest to decide which features to activate
//! and which to explicitly mark as unavailable. No silent degradation —
//! unsupported features are surfaced honestly.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use crate::events::{HookEvent, LifecycleEvent};

/// How a platform handles AI agent delegation (spawning sub-agents).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DelegationSupport {
    /// Platform has native sub-agent spawning (e.g., Claude Code's Task tool
    /// with subagent_type specialisation).
    Native,

    /// Platform can run agents sequentially but not in parallel.
    Sequential,

    /// No delegation support. Skills requiring delegation are unavailable.
    None,
}

/// How the system prompt is injected into the platform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PromptInjection {
    /// A dedicated system file loaded by the platform (e.g., CLAUDE.md, AGENTS.md).
    SystemFile,

    /// Injected via API (e.g., system message in API calls).
    Api,

    /// A rules file that the platform reads (e.g., .cursorrules).
    RulesFile,
}

/// How skills are routed to the AI agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkillRouting {
    /// YAML frontmatter with USE WHEN triggers, parsed by the platform.
    YamlFrontmatter,

    /// Skills registered in a platform-specific registry.
    Registry,

    /// Skills inlined in the system prompt as plain text.
    Inline,
}

/// How AI inference is invoked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InferenceMethod {
    /// Via a platform CLI command (e.g., `claude --print`).
    Cli,

    /// Via direct API calls to an inference provider.
    Api,
}

/// Declares what a platform adapter supports.
///
/// Locus core queries this to decide which features to activate.
/// Features requiring unsupported capabilities are explicitly marked
/// as unavailable — never silently degraded.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapabilityManifest {
    /// Which lifecycle events the platform can fire.
    pub lifecycle_events: HashSet<LifecycleEvent>,

    /// Which tool-level hook events the platform can fire.
    pub hook_events: HashSet<HookEvent>,

    /// How the platform handles agent delegation.
    pub delegation: DelegationSupport,

    /// How the system prompt reaches the AI agent.
    pub prompt_injection: PromptInjection,

    /// How skills are routed to the AI.
    pub skill_routing: SkillRouting,

    /// How AI inference is invoked for tool use.
    pub inference: InferenceMethod,

    /// Whether the platform supports MCP (Model Context Protocol) servers.
    pub mcp_support: bool,

    /// Maximum system prompt size in characters, if known.
    /// `None` means no known limit.
    pub max_prompt_size: Option<usize>,
}

impl CapabilityManifest {
    /// Check whether a specific lifecycle event is supported.
    pub fn supports_lifecycle(&self, event: &LifecycleEvent) -> bool {
        self.lifecycle_events.contains(event)
    }

    /// Check whether a specific hook event is supported.
    pub fn supports_hook(&self, event: &HookEvent) -> bool {
        self.hook_events.contains(event)
    }

    /// Check whether native agent delegation is available.
    pub fn has_native_delegation(&self) -> bool {
        self.delegation == DelegationSupport::Native
    }

    /// Check whether any form of delegation is available.
    pub fn has_delegation(&self) -> bool {
        self.delegation != DelegationSupport::None
    }

    /// Returns a list of features that are unavailable on this platform.
    pub fn unavailable_features(&self) -> Vec<UnavailableFeature> {
        let mut features = Vec::new();

        if self.delegation == DelegationSupport::None {
            features.push(UnavailableFeature {
                feature: "Agent delegation".into(),
                reason: "Platform does not support sub-agent spawning".into(),
                affected_skills: vec!["council".into(), "red-team".into(), "delegation".into()],
            });
        }

        if self.hook_events.is_empty() {
            features.push(UnavailableFeature {
                feature: "Tool-level hooks".into(),
                reason: "Platform does not fire tool hook events".into(),
                affected_skills: vec![],
            });
        }

        if !self.mcp_support {
            features.push(UnavailableFeature {
                feature: "MCP servers".into(),
                reason: "Platform does not support Model Context Protocol".into(),
                affected_skills: vec![],
            });
        }

        features
    }
}

/// Describes a feature that is explicitly unavailable on the current platform.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnavailableFeature {
    /// Human-readable feature name.
    pub feature: String,

    /// Why it's unavailable.
    pub reason: String,

    /// Skills that depend on this feature.
    pub affected_skills: Vec<String>,
}
