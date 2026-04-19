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

### Examples

| Skill | Full Mode | Degraded Mode |
|-------|-----------|---------------|
| Council | 4 parallel debate agents | Unavailable (requires delegation) |
| Red Team | 8+ parallel attack agents | Unavailable (requires delegation) |
| Research (Extensive) | 4-8 parallel research agents | Sequential research from multiple angles |
| Research (Quick) | Single-agent research | No change (doesn't need delegation) |

## Implementation

Each skill's `SKILL.md` declares its requirements in the `requires` frontmatter. The runtime checks these against the platform's `CapabilityManifest` and determines availability before invocation.
