# Moved — the coordinator protocol is `stack.v2.md`

**Read `stack.v2.md`, beside this file, and follow it. Nothing routes here any more.**
`implement.md` step 0 and the Dispatcher's `SKILL.md` both name `stack.v2.md`.

## Why this file is a signpost and not a deletion

The protocol that used to live here was replaced, not amended. Its finish line was *"every
child done, and the parent verified against its own acceptance criteria"*, and `stack.v2.md`
§10 exists to stop a coordinator making that claim: nothing in the process merges or deploys,
so a parent closed on all-children-done is one claim of evidence stretched over two. It also
closed only on all-`done`, which deadlocked forever on a single discarded child.

**The reason to keep the file is a redirect, and it needs no more than that.** Thirty lines
saying "moved, read `stack.v2.md`" cost nothing and catch anything that goes looking for the
filename the old instructions named — a worker running from a cached copy of an older brief, a
bookmark, a half-remembered path. Deleting it makes those land on nothing; keeping it makes
them land here.

There is a second, narrower reason, and it is stated carefully because an earlier version of
this file overstated it badly enough that it had to be corrected after review:

> `update_content.rs:127` — *"Content sync writes files and never removes them"* — and its one
> prune covers `algorithm/*.md` only, *"[n]ot a general sweep of the Locus home"*. The
> dispatcher **is** carried by that path: a sync into a fresh `LOCUS_HOME` produces
> `skills/dispatcher/workers/stack.md`. So once a machine has synced with this file bundled,
> deleting it from the repo would not remove it from that machine — a full copy of the
> superseded protocol would sit in the directory a coordinator reads, invisible to `git grep`.

That is a **latent** hazard, not a historical one, and the difference is the part the earlier
version got wrong. It claimed the stranding already existed "on every machine that has ever run
`locus init`". It did not: the dispatcher first shipped in v0.3.1, and no `LOCUS_HOME` had been
synced since. The mechanism was real and verified; whether it had yet applied to *these* files
was never checked, and the true fact underneath made the false inference on top read as
established. A signpost is right either way, so nothing about the decision moved — only the
reasoning recorded for it.

*(The plugin path, `~/.claude/plugins/cache/locus/locus/<version>/`, is version-scoped and
replaced wholesale, so it strands nothing. Both paths ship, and the weaker one governs.)*
