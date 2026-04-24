# Degradation Protocol

How Locus handles features that are unavailable on the current platform.

## Principle

**Honest degradation.** Never silently pretend a feature works when it doesn't. Never produce lower-quality output without telling the user.

## Behaviour

When a skill or feature requires a capability the platform doesn't support:

### Explicitly Unavailable
The feature cannot work at all without the missing capability. Tell the user clearly:

```
[Skill Name] requires [capability] which is not available on [platform].
This skill is unavailable in the current configuration.
```

### Graceful Fallback
The feature has a degraded mode that still provides value. Tell the user what's different:

```
[Skill Name] normally uses [capability] for [benefit].
On [platform], falling back to [alternative approach].
This may be [slower/less thorough/sequential instead of parallel].
```

### Tool-Level Degradation

When a platform lacks a specific tool that agents expect (e.g., `web_search`), the agent must adapt its methodology rather than fail silently:

1. **Check the tool manifest first** — before attempting any tool, verify it is in the platform's available tool list.
2. **Use the nearest equivalent** — if `web_search` is unavailable, use `web_fetch` against known URLs or `bash` with `curl`/`gh` for discovery.
3. **Declare the degradation** — state clearly in the output which tool was unavailable and how the agent adapted.

### Examples

| Skill | Full Mode | Degraded Mode |
|-------|-----------|---------------|
| Council | 4 parallel debate agents | Unavailable (requires delegation) |
| Red Team | 8+ parallel attack agents | Unavailable (requires delegation) |
| Research (Extensive) | 4-8 parallel research agents | Sequential research from multiple angles |
| Research (Quick) | Single-agent research | No change (doesn't need delegation) |
| Research (Discovery) | `web_search` for open-ended discovery | `web_fetch` against known URLs + `bash` with `curl`/`gh` |
| Research (Verification) | `web_fetch` to verify citations | No change (both platforms support fetch) |

## Implementation

Each skill's `SKILL.md` declares its requirements in the `requires` frontmatter. The runtime checks these against the platform's `CapabilityManifest` and determines availability before invocation.
