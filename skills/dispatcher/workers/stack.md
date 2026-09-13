# Moved — the coordinator protocol is `stack.v2.md`

**Read `stack.v2.md`, beside this file, and follow it. Nothing routes here any more.**
`implement.md` step 0 and the Dispatcher's `SKILL.md` both name `stack.v2.md`.

## Why this file is a signpost and not a deletion

The protocol that used to live here was replaced, not amended. Its finish line was *"every
child done, and the parent verified against its own acceptance criteria"*, and `stack.v2.md`
§10 exists to stop a coordinator making that claim: nothing in the process merges or deploys,
so a parent closed on all-children-done is one claim of evidence stretched over two. It also
closed only on all-`done`, which deadlocked forever on a single discarded child.

The obvious move was to delete the file and let git history be the archive. That is wrong, and
the reason is a fact about the installer rather than a matter of taste:

> `crates/locus-cli/src/commands/update_content.rs:127` — *"Content sync writes files and
> never removes them"*, and the one prune it has is `algorithm/*.md` only, *"[n]ot a general
> sweep of the Locus home"*.

So deleting it from the repo would have removed it from nowhere. Every machine that has ever
run `locus init` would keep a full copy of the superseded protocol at
`~/.locus/skills/dispatcher/workers/stack.md` — unreferenced, invisible to `git grep`, and
sitting in the directory a coordinator reads. It is exactly the stale file that prune
docstring was written about, in the one managed directory that has no prune.

A signpost is overwritten by the same content sync. Deleting could only ever have added a
second source of truth; this removes one.

*(The plugin install path, `~/.claude/plugins/cache/locus/locus/<version>/`, is
version-scoped and would have pruned it by construction. Both paths ship, so the weaker one
governs.)*
