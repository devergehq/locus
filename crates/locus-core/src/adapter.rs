//! Platform adapter trait.
//!
//! Every supported platform implements [`PlatformAdapter`] to translate
//! between Locus's internal model and the platform's native mechanics.
//! Adapters are thin — they handle translation, not logic.

use std::collections::HashMap;
use std::path::PathBuf;

use async_trait::async_trait;

use crate::capabilities::CapabilityManifest;
use crate::config::LocusConfig;
use crate::error::LocusError;
use crate::events::{EventContext, HookEvent, LifecycleEvent};
use crate::platform::Platform;

/// A segment of the system prompt to be injected into the platform.
///
/// The adapter assembles these segments into the platform's native
/// prompt format (e.g., CLAUDE.md, AGENTS.md, .cursorrules).
#[derive(Debug, Clone)]
pub struct PromptSegment {
    /// Identifier for this segment (e.g., "algorithm", "skill:research", "context-pack:personal").
    pub id: String,

    /// The markdown content of this segment.
    pub content: String,

    /// Priority for ordering. Lower numbers appear first in the prompt.
    /// Algorithm = 0, skills = 100, context-packs = 200, user overrides = 300.
    pub priority: u32,
}

/// A generated configuration file for the target platform.
#[derive(Debug, Clone)]
pub struct GeneratedFile {
    /// Path where the file should be written (relative to platform config dir).
    pub path: PathBuf,

    /// The file contents.
    pub content: String,

    /// Whether this file should overwrite an existing file.
    /// If false and the file exists, the adapter skips it.
    pub overwrite: bool,
}

/// Resolved paths for the Locus installation.
#[derive(Debug, Clone)]
pub struct LocusPaths {
    /// Root of the Locus core installation (e.g., ~/.locus/).
    pub home: PathBuf,

    /// Root of the user data directory (e.g., ~/.locus/data/).
    pub data: PathBuf,

    /// Path to locus.yaml configuration.
    pub config: PathBuf,

    /// Path to the algorithm spec directory.
    pub algorithm: PathBuf,

    /// Path to the skills directory.
    pub skills: PathBuf,

    /// Path to the agents directory.
    pub agents: PathBuf,

    /// Path to the protocols directory.
    pub protocols: PathBuf,

    /// Platform-specific config directory (e.g., ~/.claude/, ~/.opencode/).
    pub platform_config: PathBuf,
}

/// Request to invoke AI inference.
#[derive(Debug, Clone)]
pub struct InferenceRequest {
    /// The prompt to send.
    pub prompt: String,

    /// System instructions, if the platform supports them separately.
    pub system: Option<String>,

    /// Model to use, if the platform supports model selection.
    pub model: Option<String>,

    /// Maximum tokens in the response.
    pub max_tokens: Option<u32>,

    /// Additional platform-specific parameters.
    pub extra: HashMap<String, serde_json::Value>,
}

/// Result from an AI inference call.
#[derive(Debug, Clone)]
pub struct InferenceResult {
    /// The generated text.
    pub content: String,

    /// The model that was actually used.
    pub model: Option<String>,

    /// Token usage, if reported.
    pub usage: Option<TokenUsage>,
}

/// Token usage from an inference call.
#[derive(Debug, Clone)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
}

/// A handle that can cancel an event subscription.
pub struct EventSubscription {
    _cancel: Box<dyn FnOnce() + Send>,
}

impl EventSubscription {
    pub fn new(cancel: impl FnOnce() + Send + 'static) -> Self {
        Self {
            _cancel: Box::new(cancel),
        }
    }

    /// Cancel the subscription, stopping future event deliveries.
    pub fn cancel(self) {
        (self._cancel)();
    }
}

/// The core trait that every platform adapter must implement.
///
/// Adapters handle seven concerns:
/// 1. Declaring capabilities (what the platform supports)
/// 2. Injecting the system prompt into the platform's native format
/// 3. Subscribing to lifecycle events (session start/end/compact)
/// 4. Subscribing to tool-level hooks (pre/post tool use)
/// 5. Invoking AI inference
/// 6. Resolving filesystem paths
/// 7. Generating platform-specific configuration files
#[async_trait]
pub trait PlatformAdapter: Send + Sync {
    /// Which platform this adapter targets.
    fn platform(&self) -> Platform;

    /// Declare what this platform supports.
    ///
    /// Locus core uses this to decide which features to activate
    /// and which to mark as explicitly unavailable.
    fn capabilities(&self) -> &CapabilityManifest;

    /// Inject system prompt segments into the platform.
    ///
    /// The adapter assembles the segments (sorted by priority) into
    /// whatever format the platform expects (CLAUDE.md, AGENTS.md, etc.).
    async fn inject_prompt(&self, segments: &[PromptSegment]) -> Result<(), LocusError>;

    /// Subscribe to a lifecycle event.
    ///
    /// Returns `None` if the platform doesn't support this event
    /// (check `capabilities()` first to avoid this).
    async fn on_lifecycle(
        &self,
        event: LifecycleEvent,
        handler: Box<dyn Fn(EventContext) + Send + Sync>,
    ) -> Result<Option<EventSubscription>, LocusError>;

    /// Subscribe to a tool-level hook event.
    ///
    /// Returns `None` if the platform doesn't support this event.
    async fn on_hook(
        &self,
        event: HookEvent,
        handler: Box<dyn Fn(EventContext) + Send + Sync>,
    ) -> Result<Option<EventSubscription>, LocusError>;

    /// Invoke AI inference through the platform.
    ///
    /// Some platforms have a native CLI for this (e.g., `claude --print`),
    /// others require direct API calls.
    async fn infer(&self, request: InferenceRequest) -> Result<InferenceResult, LocusError>;

    /// Resolve all Locus-relevant paths for this platform.
    fn resolve_paths(&self, config: &LocusConfig) -> Result<LocusPaths, LocusError>;

    /// Generate platform-specific configuration files.
    ///
    /// Takes the canonical Locus config and produces the files the platform
    /// needs (CLAUDE.md, settings.json, opencode.json, etc.).
    async fn generate_config(&self, config: &LocusConfig)
        -> Result<Vec<GeneratedFile>, LocusError>;
}
