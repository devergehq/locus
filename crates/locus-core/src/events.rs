//! Locus event model.
//!
//! Defines the internal lifecycle and hook events that Locus uses.
//! Platform adapters map these to their native event systems.
//! Not every platform supports every event — adapters declare
//! which events they handle via [`CapabilityManifest`](crate::capabilities::CapabilityManifest).

use serde::{Deserialize, Serialize};

/// High-level session lifecycle events.
///
/// These represent the major phase transitions in an AI coding session.
/// Every platform supports at least `SessionStart` and `SessionEnd`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleEvent {
    /// A new session has started.
    SessionStart,

    /// The session is ending (user quit or session timeout).
    SessionEnd,

    /// The context window was compacted (summarised to free space).
    ContextCompact,

    /// The session was suspended (e.g., Allele suspending a session).
    SessionSuspend,

    /// The session was resumed from a suspended state.
    SessionResume,
}

/// Tool-level hook events.
///
/// These fire around specific tool invocations within a session.
/// Many platforms don't support these — adapters declare support
/// via their capability manifest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookEvent {
    /// Fires before a tool is invoked. Can be used for validation,
    /// security checks, or context injection.
    PreToolUse,

    /// Fires after a tool completes. Can be used for logging,
    /// learning capture, or state updates.
    PostToolUse,

    /// Fires before a file is written. Can be used for security
    /// validation or backup.
    PreFileWrite,

    /// Fires when the user submits a new prompt.
    UserPromptSubmit,

    /// Fires when the AI produces a response (before it's displayed).
    ResponseReady,

    /// A notification from the AI (status update, progress, etc.).
    Notification,
}

/// Context about a specific event occurrence.
///
/// Passed to event handlers with details about what triggered the event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventContext {
    /// Which event fired.
    pub event: EventKind,

    /// The session ID, if available.
    pub session_id: Option<String>,

    /// The tool name, for tool-level hooks.
    pub tool_name: Option<String>,

    /// The tool input, for tool-level hooks.
    pub tool_input: Option<serde_json::Value>,

    /// Arbitrary metadata from the platform.
    pub metadata: serde_json::Value,
}

/// Unified event kind encompassing both lifecycle and hook events.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum EventKind {
    Lifecycle(LifecycleEvent),
    Hook(HookEvent),
}

impl From<LifecycleEvent> for EventKind {
    fn from(e: LifecycleEvent) -> Self {
        Self::Lifecycle(e)
    }
}

impl From<HookEvent> for EventKind {
    fn from(e: HookEvent) -> Self {
        Self::Hook(e)
    }
}

impl LifecycleEvent {
    /// Returns all lifecycle event variants.
    pub fn all() -> &'static [LifecycleEvent] {
        &[
            Self::SessionStart,
            Self::SessionEnd,
            Self::ContextCompact,
            Self::SessionSuspend,
            Self::SessionResume,
        ]
    }
}

impl HookEvent {
    /// Returns all hook event variants.
    pub fn all() -> &'static [HookEvent] {
        &[
            Self::PreToolUse,
            Self::PostToolUse,
            Self::PreFileWrite,
            Self::UserPromptSubmit,
            Self::ResponseReady,
            Self::Notification,
        ]
    }
}
