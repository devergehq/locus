//! Skill, workflow, and tool type definitions.
//!
//! Skills are the primary unit of capability in Locus. Each skill
//! is a modular, composable unit with its own workflows, triggers,
//! and optional tool dependencies.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A skill definition, parsed from a SKILL.md file's YAML frontmatter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillDefinition {
    /// Unique skill identifier (kebab-case slug).
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Short description of what the skill does.
    pub description: String,

    /// Trigger phrases that activate this skill.
    /// Matched against user prompts using keyword matching.
    pub triggers: Vec<String>,

    /// Workflows available within this skill.
    pub workflows: Vec<WorkflowRef>,

    /// Categories/tags for organisation and discovery.
    #[serde(default)]
    pub tags: Vec<String>,

    /// Skills that this skill depends on (by ID).
    #[serde(default)]
    pub dependencies: Vec<String>,

    /// Capabilities required from the platform.
    /// If any required capability is missing, the skill is unavailable.
    #[serde(default)]
    pub requires: SkillRequirements,

    /// Path to the SKILL.md file on disk.
    #[serde(skip)]
    pub source_path: Option<PathBuf>,
}

/// Capabilities a skill requires from the platform.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SkillRequirements {
    /// Requires agent delegation support.
    #[serde(default)]
    pub delegation: bool,

    /// Requires specific hook events.
    #[serde(default)]
    pub hook_events: Vec<String>,

    /// Requires AI inference capability.
    #[serde(default)]
    pub inference: bool,

    /// Requires MCP support.
    #[serde(default)]
    pub mcp: bool,
}

/// A reference to a workflow within a skill.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowRef {
    /// Workflow identifier (e.g., "quick", "standard", "extensive").
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Short description.
    pub description: String,

    /// Relative path to the workflow markdown file.
    pub path: String,
}

/// A loaded workflow with its full content.
#[derive(Debug, Clone)]
pub struct Workflow {
    /// The workflow reference from the skill definition.
    pub reference: WorkflowRef,

    /// The full markdown content of the workflow.
    pub content: String,
}

/// A tool that skills can invoke.
///
/// Tools are built-in Rust implementations that perform specific
/// operations (inference, indexing, sync, etc.).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDefinition {
    /// Unique tool identifier.
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Short description of what the tool does.
    pub description: String,

    /// Input parameters the tool accepts (as JSON Schema).
    #[serde(default)]
    pub input_schema: Option<serde_json::Value>,

    /// Output format description.
    #[serde(default)]
    pub output_description: Option<String>,
}

/// An agent role definition, parsed from an agent markdown file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentDefinition {
    /// Unique agent identifier (e.g., "architect", "engineer").
    pub id: String,

    /// Human-readable role name.
    pub name: String,

    /// The domain this agent specialises in.
    pub domain: String,

    /// Description of the agent's perspective and focus.
    pub description: String,

    /// Path to the agent definition file on disk.
    #[serde(skip)]
    pub source_path: Option<PathBuf>,
}

/// The result of checking whether a skill is available on the current platform.
#[derive(Debug, Clone)]
pub enum SkillAvailability {
    /// Skill is fully available.
    Available,

    /// Skill is available but some features are degraded.
    Degraded {
        /// What's missing.
        missing: Vec<String>,
    },

    /// Skill is unavailable due to missing platform capabilities.
    Unavailable {
        /// Why it's unavailable.
        reason: String,
    },
}
