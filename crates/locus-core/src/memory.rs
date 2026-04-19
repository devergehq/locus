//! Memory schema types.
//!
//! Defines the structure of Locus's persistent memory system.
//! Memory lives in the user data directory (`~/.locus/data/memory/`)
//! and is version-controlled separately from the core system.

use serde::{Deserialize, Serialize};

/// Categories of memory that Locus persists.
///
/// Each category maps to a subdirectory in `~/.locus/data/memory/`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryCategory {
    /// Work artifacts — PRDs, implementation state, checkpoints.
    Work,

    /// Session learnings — insights, patterns, failure analysis.
    Learning,

    /// Research outputs — agent research archives.
    Research,

    /// Runtime state — ephemeral, not synced between machines.
    State,
}

impl MemoryCategory {
    /// Returns the directory name for this category.
    pub fn dir_name(&self) -> &'static str {
        match self {
            Self::Work => "work",
            Self::Learning => "learning",
            Self::Research => "research",
            Self::State => "state",
        }
    }

    /// Returns all memory categories.
    pub fn all() -> &'static [MemoryCategory] {
        &[Self::Work, Self::Learning, Self::Research, Self::State]
    }

    /// Whether this category should be synced between machines.
    pub fn is_syncable(&self) -> bool {
        !matches!(self, Self::State)
    }
}

/// A single learning entry, persisted as markdown with YAML frontmatter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LearningEntry {
    /// ISO 8601 timestamp of when the learning was captured.
    pub timestamp: String,

    /// Short summary of the learning.
    pub summary: String,

    /// The full content (markdown).
    pub content: String,

    /// Tags for categorisation and retrieval.
    #[serde(default)]
    pub tags: Vec<String>,

    /// The project context, if this learning is project-scoped.
    #[serde(default)]
    pub project: Option<String>,

    /// The session ID that generated this learning.
    #[serde(default)]
    pub session_id: Option<String>,

    /// Confidence level of the learning (0.0 to 1.0).
    /// Higher = more verified/tested.
    #[serde(default = "LearningEntry::default_confidence")]
    pub confidence: f32,
}

impl LearningEntry {
    fn default_confidence() -> f32 {
        0.5
    }
}

/// Per-project memory, stored in `~/.locus/data/projects/{slug}/`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectMemory {
    /// Project identifier (slug).
    pub slug: String,

    /// Human-readable project name.
    pub name: String,

    /// Filesystem paths associated with this project.
    #[serde(default)]
    pub paths: Vec<String>,

    /// Glob patterns that match this project.
    #[serde(default)]
    pub patterns: Vec<String>,
}

/// A context pack — optional user/org context that enriches AI interactions.
///
/// Stored in `~/.locus/data/context-packs/{pack-name}/`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextPack {
    /// Pack identifier.
    pub id: String,

    /// Human-readable name.
    pub name: String,

    /// Whether this pack is currently active.
    #[serde(default)]
    pub active: bool,

    /// The markdown content files in this pack.
    #[serde(default)]
    pub files: Vec<String>,
}
