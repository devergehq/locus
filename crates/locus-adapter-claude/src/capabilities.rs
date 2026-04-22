//! Claude Code capability manifest.

use std::collections::HashSet;

use locus_core::capabilities::{
    CapabilityManifest, DelegationSupport, InferenceMethod, PromptInjection, SkillRouting,
};
use locus_core::events::{HookEvent, LifecycleEvent};

/// Build the capability manifest for Claude Code.
///
/// Claude Code supports nine hook events via settings.json (SessionStart,
/// Stop, PreCompact, PreToolUse, PostToolUse, UserPromptSubmit, Notification,
/// SubagentStop, and session-end via Stop on the primary agent), native
/// agent delegation via the Task tool, CLAUDE.md prompt injection, CLI-based
/// inference via `claude -p`, and full MCP server support.
///
/// Skill routing is declared as `Inline` — Locus keeps the Algorithm as the
/// sole orchestration layer, so skills are loaded by the Algorithm via Read
/// rather than surfaced as native Claude Code skills. This matches the
/// OpenCode adapter's philosophy.
pub fn claude_capabilities() -> CapabilityManifest {
    let mut lifecycle_events = HashSet::new();
    lifecycle_events.insert(LifecycleEvent::SessionStart);
    lifecycle_events.insert(LifecycleEvent::SessionEnd);
    lifecycle_events.insert(LifecycleEvent::ContextCompact);
    // SessionSuspend and SessionResume are not natively supported by Claude Code.

    let mut hook_events = HashSet::new();
    hook_events.insert(HookEvent::PreToolUse);
    hook_events.insert(HookEvent::PostToolUse);
    hook_events.insert(HookEvent::UserPromptSubmit);
    hook_events.insert(HookEvent::ResponseReady);
    hook_events.insert(HookEvent::Notification);
    // PreFileWrite is available via PreToolUse with a Write|Edit matcher.
    hook_events.insert(HookEvent::PreFileWrite);

    CapabilityManifest {
        lifecycle_events,
        hook_events,
        delegation: DelegationSupport::Native,
        prompt_injection: PromptInjection::SystemFile,
        skill_routing: SkillRouting::Inline,
        inference: InferenceMethod::Cli,
        mcp_support: true,
        max_prompt_size: None,
    }
}
