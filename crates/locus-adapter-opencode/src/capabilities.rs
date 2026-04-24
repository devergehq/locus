//! OpenCode capability manifest.

use std::collections::HashSet;

use locus_core::capabilities::{
    CapabilityManifest, DelegationSupport, InferenceMethod, PromptInjection, SkillRouting,
};
use locus_core::events::{HookEvent, LifecycleEvent};

/// Build the capability manifest for OpenCode.
///
/// OpenCode supports 16+ bus events, in-process plugins, AGENTS.md
/// system prompt injection, and agent delegation via the Task tool.
pub fn opencode_capabilities() -> CapabilityManifest {
    let mut lifecycle_events = HashSet::new();
    lifecycle_events.insert(LifecycleEvent::SessionStart);
    lifecycle_events.insert(LifecycleEvent::SessionEnd);
    lifecycle_events.insert(LifecycleEvent::ContextCompact);
    // SessionSuspend and SessionResume are not natively supported by OpenCode.

    let mut hook_events = HashSet::new();
    hook_events.insert(HookEvent::PreToolUse);
    hook_events.insert(HookEvent::PostToolUse);
    hook_events.insert(HookEvent::UserPromptSubmit);
    hook_events.insert(HookEvent::ResponseReady);
    hook_events.insert(HookEvent::Notification);
    // PreFileWrite is available via file.edited event.
    hook_events.insert(HookEvent::PreFileWrite);

    let mut available_tools = HashSet::new();
    available_tools.insert("glob".to_string());
    available_tools.insert("grep".to_string());
    available_tools.insert("read".to_string());
    available_tools.insert("edit".to_string());
    available_tools.insert("bash".to_string());
    available_tools.insert("web_fetch".to_string());
    available_tools.insert("task".to_string());
    // WebSearch is only available when OPENCODE_ENABLE_EXA=1 is set.
    if std::env::var("OPENCODE_ENABLE_EXA").is_ok_and(|v| !v.is_empty() && v != "0") {
        available_tools.insert("web_search".to_string());
    }

    CapabilityManifest {
        lifecycle_events,
        hook_events,
        delegation: DelegationSupport::Native,
        prompt_injection: PromptInjection::SystemFile,
        skill_routing: SkillRouting::Inline,
        inference: InferenceMethod::Api,
        mcp_support: true,
        max_prompt_size: None,
        available_tools,
    }
}
