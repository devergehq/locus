//! Locus-to-Claude-Code event mapping.
//!
//! Maps Locus's internal event model to Claude Code's hook names as
//! they appear under the `hooks` key in `~/.claude/settings.json`.

use locus_core::events::{HookEvent, LifecycleEvent};

/// A Claude Code hook mapping — the settings.json key plus any matcher filter.
pub struct ClaudeEventMapping {
    /// The settings.json hook key (e.g., "PreToolUse", "SessionStart").
    pub hook_name: &'static str,

    /// Optional tool matcher, used on PreToolUse / PostToolUse to restrict
    /// the hook to specific tools (e.g., "Write|Edit" for PreFileWrite).
    pub matcher: Option<&'static str>,
}

/// Map a Locus lifecycle event to a Claude Code hook.
pub fn map_lifecycle_event(event: &LifecycleEvent) -> Option<ClaudeEventMapping> {
    match event {
        LifecycleEvent::SessionStart => Some(ClaudeEventMapping {
            hook_name: "SessionStart",
            matcher: None,
        }),
        LifecycleEvent::SessionEnd => Some(ClaudeEventMapping {
            hook_name: "Stop",
            matcher: None,
        }),
        LifecycleEvent::ContextCompact => Some(ClaudeEventMapping {
            hook_name: "PreCompact",
            matcher: None,
        }),
        // Not natively supported by Claude Code.
        LifecycleEvent::SessionSuspend => None,
        LifecycleEvent::SessionResume => None,
    }
}

/// Map a Locus hook event to a Claude Code hook.
pub fn map_hook_event(event: &HookEvent) -> Option<ClaudeEventMapping> {
    match event {
        HookEvent::PreToolUse => Some(ClaudeEventMapping {
            hook_name: "PreToolUse",
            matcher: None,
        }),
        HookEvent::PostToolUse => Some(ClaudeEventMapping {
            hook_name: "PostToolUse",
            matcher: None,
        }),
        HookEvent::UserPromptSubmit => Some(ClaudeEventMapping {
            hook_name: "UserPromptSubmit",
            matcher: None,
        }),
        HookEvent::ResponseReady => Some(ClaudeEventMapping {
            hook_name: "Stop",
            matcher: None,
        }),
        HookEvent::PreFileWrite => Some(ClaudeEventMapping {
            hook_name: "PreToolUse",
            matcher: Some("Write|Edit"),
        }),
        HookEvent::Notification => Some(ClaudeEventMapping {
            hook_name: "Notification",
            matcher: None,
        }),
    }
}
