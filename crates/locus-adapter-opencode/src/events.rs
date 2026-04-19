//! Locus-to-OpenCode event mapping.
//!
//! Maps Locus's internal event model to OpenCode's plugin hook names
//! and bus event types.

use locus_core::events::{HookEvent, LifecycleEvent};

/// OpenCode hook name that an event maps to.
pub struct OpenCodeEventMapping {
    /// The OpenCode hook or bus event name.
    pub hook_name: &'static str,

    /// Optional bus event type filter (for events routed through the `event` hook).
    pub bus_event_type: Option<&'static str>,
}

/// Map a Locus lifecycle event to an OpenCode hook.
pub fn map_lifecycle_event(event: &LifecycleEvent) -> Option<OpenCodeEventMapping> {
    match event {
        LifecycleEvent::SessionStart => Some(OpenCodeEventMapping {
            hook_name: "experimental.chat.system.transform",
            bus_event_type: Some("session.created"),
        }),
        LifecycleEvent::SessionEnd => Some(OpenCodeEventMapping {
            hook_name: "event",
            bus_event_type: Some("session.ended"),
        }),
        LifecycleEvent::ContextCompact => Some(OpenCodeEventMapping {
            hook_name: "experimental.session.compacting",
            bus_event_type: Some("session.compacted"),
        }),
        // Not natively supported by OpenCode.
        LifecycleEvent::SessionSuspend => None,
        LifecycleEvent::SessionResume => None,
    }
}

/// Map a Locus hook event to an OpenCode hook.
pub fn map_hook_event(event: &HookEvent) -> Option<OpenCodeEventMapping> {
    match event {
        HookEvent::PreToolUse => Some(OpenCodeEventMapping {
            hook_name: "tool.execute.before",
            bus_event_type: None,
        }),
        HookEvent::PostToolUse => Some(OpenCodeEventMapping {
            hook_name: "tool.execute.after",
            bus_event_type: None,
        }),
        HookEvent::UserPromptSubmit => Some(OpenCodeEventMapping {
            hook_name: "chat.message",
            bus_event_type: None,
        }),
        HookEvent::ResponseReady => Some(OpenCodeEventMapping {
            hook_name: "event",
            bus_event_type: Some("message.updated"),
        }),
        HookEvent::PreFileWrite => Some(OpenCodeEventMapping {
            hook_name: "event",
            bus_event_type: Some("file.edited"),
        }),
        HookEvent::Notification => Some(OpenCodeEventMapping {
            hook_name: "event",
            bus_event_type: Some("session.updated"),
        }),
    }
}
