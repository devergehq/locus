//! Bundled content files embedded at compile time.
//!
//! This module centralises all `include_str!` calls so that both
//! `locus init` and `locus update-content` share the same file list.

/// Returns all bundled files as `(relative_path, embedded_content)` pairs.
///
/// The relative paths are rooted at the Locus home directory (`~/.locus/`).
pub fn bundled_files() -> Vec<(String, &'static str)> {
    vec![
        // Algorithm
        (
            format!("algorithm/{}", locus_core::ALGORITHM_FILE),
            include_str!("../../../algorithm/v2.0.md"),
        ),
        // Skills — top-level SKILL.md files
        (
            "skills/research/SKILL.md".into(),
            include_str!("../../../skills/research/SKILL.md"),
        ),
        (
            "skills/research/UrlVerificationProtocol.md".into(),
            include_str!("../../../skills/research/UrlVerificationProtocol.md"),
        ),
        (
            "skills/research/AdversarialVerificationProtocol.md".into(),
            include_str!("../../../skills/research/AdversarialVerificationProtocol.md"),
        ),
        (
            "skills/research/Workflows/Standard.md".into(),
            include_str!("../../../skills/research/Workflows/Standard.md"),
        ),
        (
            "skills/research/Workflows/Interview.md".into(),
            include_str!("../../../skills/research/Workflows/Interview.md"),
        ),
        (
            "skills/research/Workflows/ExtractAlpha.md".into(),
            include_str!("../../../skills/research/Workflows/ExtractAlpha.md"),
        ),
        (
            "skills/research/Workflows/Quick.md".into(),
            include_str!("../../../skills/research/Workflows/Quick.md"),
        ),
        (
            "skills/research/Workflows/Extensive.md".into(),
            include_str!("../../../skills/research/Workflows/Extensive.md"),
        ),
        (
            "skills/research/Workflows/Deep.md".into(),
            include_str!("../../../skills/research/Workflows/Deep.md"),
        ),
        (
            "skills/research/Workflows/ExtractKnowledge.md".into(),
            include_str!("../../../skills/research/Workflows/ExtractKnowledge.md"),
        ),
        (
            "skills/research/Workflows/YoutubeExtraction.md".into(),
            include_str!("../../../skills/research/Workflows/YoutubeExtraction.md"),
        ),
        (
            "skills/research/Workflows/WebScraping.md".into(),
            include_str!("../../../skills/research/Workflows/WebScraping.md"),
        ),
        (
            "skills/research/Workflows/Enhance.md".into(),
            include_str!("../../../skills/research/Workflows/Enhance.md"),
        ),
        (
            "skills/research/Workflows/Retrieve.md".into(),
            include_str!("../../../skills/research/Workflows/Retrieve.md"),
        ),
        (
            "skills/first-principles/SKILL.md".into(),
            include_str!("../../../skills/first-principles/SKILL.md"),
        ),
        (
            "skills/first-principles/Workflows/Decompose.md".into(),
            include_str!("../../../skills/first-principles/Workflows/Decompose.md"),
        ),
        (
            "skills/iterative-depth/SKILL.md".into(),
            include_str!("../../../skills/iterative-depth/SKILL.md"),
        ),
        (
            "skills/iterative-depth/TheLenses.md".into(),
            include_str!("../../../skills/iterative-depth/TheLenses.md"),
        ),
        (
            "skills/iterative-depth/ScientificFoundation.md".into(),
            include_str!("../../../skills/iterative-depth/ScientificFoundation.md"),
        ),
        (
            "skills/iterative-depth/Workflows/Explore.md".into(),
            include_str!("../../../skills/iterative-depth/Workflows/Explore.md"),
        ),
        (
            "skills/council/SKILL.md".into(),
            include_str!("../../../skills/council/SKILL.md"),
        ),
        (
            "skills/council/CouncilMembers.md".into(),
            include_str!("../../../skills/council/CouncilMembers.md"),
        ),
        (
            "skills/council/RoundStructure.md".into(),
            include_str!("../../../skills/council/RoundStructure.md"),
        ),
        (
            "skills/council/OutputFormat.md".into(),
            include_str!("../../../skills/council/OutputFormat.md"),
        ),
        (
            "skills/council/Workflows/Debate.md".into(),
            include_str!("../../../skills/council/Workflows/Debate.md"),
        ),
        (
            "skills/council/Workflows/Quick.md".into(),
            include_str!("../../../skills/council/Workflows/Quick.md"),
        ),
        (
            "skills/red-team/SKILL.md".into(),
            include_str!("../../../skills/red-team/SKILL.md"),
        ),
        (
            "skills/red-team/Philosophy.md".into(),
            include_str!("../../../skills/red-team/Philosophy.md"),
        ),
        (
            "skills/red-team/Integration.md".into(),
            include_str!("../../../skills/red-team/Integration.md"),
        ),
        (
            "skills/red-team/Workflows/ParallelAnalysis.md".into(),
            include_str!("../../../skills/red-team/Workflows/ParallelAnalysis.md"),
        ),
        (
            "skills/red-team/Workflows/AdversarialValidation.md".into(),
            include_str!("../../../skills/red-team/Workflows/AdversarialValidation.md"),
        ),
        (
            "skills/creative/SKILL.md".into(),
            include_str!("../../../skills/creative/SKILL.md"),
        ),
        (
            "skills/creative/Principles.md".into(),
            include_str!("../../../skills/creative/Principles.md"),
        ),
        (
            "skills/creative/Examples.md".into(),
            include_str!("../../../skills/creative/Examples.md"),
        ),
        (
            "skills/creative/Templates.md".into(),
            include_str!("../../../skills/creative/Templates.md"),
        ),
        (
            "skills/creative/ResearchFoundation.md".into(),
            include_str!("../../../skills/creative/ResearchFoundation.md"),
        ),
        (
            "skills/science/SKILL.md".into(),
            include_str!("../../../skills/science/SKILL.md"),
        ),
        (
            "skills/science/METHODOLOGY.md".into(),
            include_str!("../../../skills/science/METHODOLOGY.md"),
        ),
        (
            "skills/science/Protocol.md".into(),
            include_str!("../../../skills/science/Protocol.md"),
        ),
        (
            "skills/science/Templates.md".into(),
            include_str!("../../../skills/science/Templates.md"),
        ),
        (
            "skills/science/Examples.md".into(),
            include_str!("../../../skills/science/Examples.md"),
        ),
        (
            "skills/science/Workflows/FullCycle.md".into(),
            include_str!("../../../skills/science/Workflows/FullCycle.md"),
        ),
        (
            "skills/science/Workflows/QuickDiagnosis.md".into(),
            include_str!("../../../skills/science/Workflows/QuickDiagnosis.md"),
        ),
        (
            "skills/science/Workflows/DefineGoal.md".into(),
            include_str!("../../../skills/science/Workflows/DefineGoal.md"),
        ),
        (
            "skills/extract-wisdom/SKILL.md".into(),
            include_str!("../../../skills/extract-wisdom/SKILL.md"),
        ),
        (
            "skills/documents/SKILL.md".into(),
            include_str!("../../../skills/documents/SKILL.md"),
        ),
        (
            "skills/security/SKILL.md".into(),
            include_str!("../../../skills/security/SKILL.md"),
        ),
        // Generated from algorithm/v2.0.md by scripts/gen-algorithm-skill.sh.
        // Bundled as well as shipped in the plugin so the binary install path
        // and the plugin install path carry the same Algorithm.
        (
            "skills/locus-algorithm/SKILL.md".into(),
            include_str!("../../../skills/locus-algorithm/SKILL.md"),
        ),
        (
            "skills/media/SKILL.md".into(),
            include_str!("../../../skills/media/SKILL.md"),
        ),
        (
            "skills/media/Workflows/ImageGeneration.md".into(),
            include_str!("../../../skills/media/Workflows/ImageGeneration.md"),
        ),
        (
            "skills/parser/SKILL.md".into(),
            include_str!("../../../skills/parser/SKILL.md"),
        ),
        (
            "skills/delegation/SKILL.md".into(),
            include_str!("../../../skills/delegation/SKILL.md"),
        ),
        // Dispatcher — the Dispatcher's own brief, its program, and one brief per worker mode.
        // `config.example.json` is the template `init` fills; without it `init` cannot run.
        // Per-instance config and runtime live in ~/.locus/data/dispatcher/<slug>/, never here.
        (
            "skills/dispatcher/SKILL.md".into(),
            include_str!("../../../skills/dispatcher/SKILL.md"),
        ),
        (
            "skills/dispatcher/dispatcher.py".into(),
            include_str!("../../../skills/dispatcher/dispatcher.py"),
        ),
        (
            "skills/dispatcher/config.example.json".into(),
            include_str!("../../../skills/dispatcher/config.example.json"),
        ),
        (
            "skills/dispatcher/workers/_common.md".into(),
            include_str!("../../../skills/dispatcher/workers/_common.md"),
        ),
        (
            "skills/dispatcher/workers/implement.md".into(),
            include_str!("../../../skills/dispatcher/workers/implement.md"),
        ),
        (
            "skills/dispatcher/workers/investigate.md".into(),
            include_str!("../../../skills/dispatcher/workers/investigate.md"),
        ),
        (
            "skills/dispatcher/workers/decompose.md".into(),
            include_str!("../../../skills/dispatcher/workers/decompose.md"),
        ),
        (
            "skills/dispatcher/workers/review.md".into(),
            include_str!("../../../skills/dispatcher/workers/review.md"),
        ),
        (
            "skills/dispatcher/workers/decide.md".into(),
            include_str!("../../../skills/dispatcher/workers/decide.md"),
        ),
        (
            "skills/dispatcher/workers/stack.md".into(),
            include_str!("../../../skills/dispatcher/workers/stack.md"),
        ),
        (
            "skills/dispatcher/workers/stack.v2.md".into(),
            include_str!("../../../skills/dispatcher/workers/stack.v2.md"),
        ),
        // Review craft — the method a review is written to, shared by review.md,
        // _common.md, implement.md and the worked example.
        (
            "skills/review-craft/SKILL.md".into(),
            include_str!("../../../skills/review-craft/SKILL.md"),
        ),
        (
            "skills/review-craft/house-style.md".into(),
            include_str!("../../../skills/review-craft/house-style.md"),
        ),
        (
            "skills/review-craft/lenses.md".into(),
            include_str!("../../../skills/review-craft/lenses.md"),
        ),
        (
            "skills/review-craft/review_lint.py".into(),
            include_str!("../../../skills/review-craft/review_lint.py"),
        ),
        (
            "skills/review-craft/examples/synthetic-billing-review.md".into(),
            include_str!("../../../skills/review-craft/examples/synthetic-billing-review.md"),
        ),
        // Issue craft - sibling to review-craft: how a Linear issue is written, so a
        // human can decide on the first screen and an agent can build from the rest.
        (
            "skills/issue-craft/SKILL.md".into(),
            include_str!("../../../skills/issue-craft/SKILL.md"),
        ),
        (
            "skills/issue-craft/house-style.md".into(),
            include_str!("../../../skills/issue-craft/house-style.md"),
        ),
        (
            "skills/issue-craft/issue_lint.py".into(),
            include_str!("../../../skills/issue-craft/issue_lint.py"),
        ),
        (
            "skills/issue-craft/examples/synthetic-defect-ticket.md".into(),
            include_str!("../../../skills/issue-craft/examples/synthetic-defect-ticket.md"),
        ),
        // Agents — traits data + archetype files
        (
            "agents/traits.yaml".into(),
            include_str!("../../../agents/traits.yaml"),
        ),
        (
            "agents/architect.md".into(),
            include_str!("../../../agents/architect.md"),
        ),
        (
            "agents/engineer.md".into(),
            include_str!("../../../agents/engineer.md"),
        ),
        (
            "agents/researcher.md".into(),
            include_str!("../../../agents/researcher.md"),
        ),
        (
            "agents/security.md".into(),
            include_str!("../../../agents/security.md"),
        ),
        (
            "agents/designer.md".into(),
            include_str!("../../../agents/designer.md"),
        ),
        (
            "agents/qa-tester.md".into(),
            include_str!("../../../agents/qa-tester.md"),
        ),
        (
            "agents/artist.md".into(),
            include_str!("../../../agents/artist.md"),
        ),
        (
            "agents/ui-reviewer.md".into(),
            include_str!("../../../agents/ui-reviewer.md"),
        ),
        (
            "agents/pentester.md".into(),
            include_str!("../../../agents/pentester.md"),
        ),
        (
            "agents/plan-agent.md".into(),
            include_str!("../../../agents/plan-agent.md"),
        ),
        (
            "agents/algorithm-agent.md".into(),
            include_str!("../../../agents/algorithm-agent.md"),
        ),
        (
            "agents/academic-researcher.md".into(),
            include_str!("../../../agents/academic-researcher.md"),
        ),
        (
            "agents/investigative-researcher.md".into(),
            include_str!("../../../agents/investigative-researcher.md"),
        ),
        (
            "agents/contrarian-researcher.md".into(),
            include_str!("../../../agents/contrarian-researcher.md"),
        ),
        (
            "agents/multi-angle-researcher.md".into(),
            include_str!("../../../agents/multi-angle-researcher.md"),
        ),
        (
            "agents/deep-investigation-researcher.md".into(),
            include_str!("../../../agents/deep-investigation-researcher.md"),
        ),
        (
            "agents/adversarial-verifier.md".into(),
            include_str!("../../../agents/adversarial-verifier.md"),
        ),
        // Protocols
        (
            "protocols/context-management.md".into(),
            include_str!("../../../protocols/context-management.md"),
        ),
        (
            "protocols/degradation.md".into(),
            include_str!("../../../protocols/degradation.md"),
        ),
        (
            "protocols/memory-schema.md".into(),
            include_str!("../../../protocols/memory-schema.md"),
        ),
        (
            "protocols/messaging.md".into(),
            include_str!("../../../protocols/messaging.md"),
        ),
        (
            "protocols/orchestration.md".into(),
            include_str!("../../../protocols/orchestration.md"),
        ),
        // Scripts — statusline, etc. Installed executable.
        (
            "scripts/statusline.sh".into(),
            include_str!("../../../scripts/statusline.sh"),
        ),
    ]
}

#[cfg(test)]
mod drift_tests {
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repo root")
    }

    fn bundled_paths() -> HashSet<String> {
        super::bundled_files()
            .into_iter()
            .map(|(rel, _)| rel.replace('\\', "/"))
            .collect()
    }

    /// `include_str!` needs a literal path, so the Algorithm filename exists in
    /// two places: `locus_core::ALGORITHM_FILE`, which every reader uses, and
    /// the literal here. If they drift, the CLI installs one file while every
    /// directive tells sessions to read another — and the install still
    /// succeeds, so nothing surfaces it until a session cannot find the spec.
    ///
    /// Comparing content rather than filenames is deliberate: a literal
    /// pointing at a different but existing file would still compile.
    #[test]
    fn bundled_algorithm_is_the_one_every_reader_expects() {
        let expected_key = format!("algorithm/{}", locus_core::ALGORITHM_FILE);

        let (_, bundled_content) = super::bundled_files()
            .into_iter()
            .find(|(rel, _)| rel == &expected_key)
            .unwrap_or_else(|| {
                panic!(
                    "nothing bundled at `{expected_key}` — locus_core::ALGORITHM_FILE \
                     and the include_str! literal in bundled.rs disagree"
                )
            });

        let on_disk = std::fs::read_to_string(
            repo_root()
                .join("algorithm")
                .join(locus_core::ALGORITHM_FILE),
        )
        .expect("Algorithm file missing at the path ALGORITHM_FILE names");

        assert_eq!(
            bundled_content,
            on_disk,
            "bundled Algorithm content differs from algorithm/{} — the \
             include_str! literal points at a different file",
            locus_core::ALGORITHM_FILE
        );
    }

    /// A stale spec left in the repo is a second source of truth.
    #[test]
    fn exactly_one_algorithm_version_exists() {
        let versions: Vec<String> = std::fs::read_dir(repo_root().join("algorithm"))
            .expect("algorithm dir")
            .flatten()
            .filter_map(|e| {
                let p = e.path();
                p.extension()
                    .is_some_and(|x| x == "md")
                    .then(|| p.file_name()?.to_str().map(str::to_string))
                    .flatten()
            })
            .collect();

        assert_eq!(
            versions,
            vec![locus_core::ALGORITHM_FILE.to_string()],
            "expected exactly one Algorithm spec, found {versions:?}"
        );
    }

    /// `include_str!` is a compile-time macro, so the bundle list cannot be
    /// enumerated at runtime — it has to be written by hand. This test is the
    /// thing that stops a hand-written list drifting silently, which is exactly
    /// how two protocols came to exist in-repo while never being installed.
    #[test]
    fn every_repo_protocol_is_bundled() {
        let bundled = bundled_paths();
        let dir = repo_root().join("protocols");

        let missing: Vec<String> = std::fs::read_dir(&dir)
            .expect("protocols dir")
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "md"))
            .filter_map(|p| {
                let rel = format!("protocols/{}", p.file_name()?.to_str()?);
                (!bundled.contains(&rel)).then_some(rel)
            })
            .collect();

        assert!(
            missing.is_empty(),
            "protocols exist in-repo but are not bundled, so `locus init` will \
             never install them and no session will ever load them: {missing:?}\n\
             Add an include_str! entry in bundled.rs for each."
        );
    }

    /// Every markdown file under skills/, not merely each SKILL.md. A skill's
    /// supporting files (Workflows/, Philosophy.md, …) are loaded by the skill
    /// itself, so omitting one installs a skill that half-works — which is
    /// harder to notice than one that is missing outright.
    #[test]
    fn every_repo_skill_file_is_bundled() {
        let bundled = bundled_paths();
        let root = repo_root();
        let mut missing = Vec::new();
        let mut stack = vec![root.join("skills")];

        while let Some(dir) = stack.pop() {
            for entry in std::fs::read_dir(&dir).expect("skills dir").flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if path
                    .extension()
                    .and_then(|x| x.to_str())
                    // Not just markdown. A skill may ship an executable
                    // companion, and filtering on `.md` alone made those
                    // invisible here *and* absent from `locus init` — the
                    // check passed while the skill shipped half-working.
                    //
                    // `json` joined the list for the same reason one step later:
                    // the dispatcher skill reads `config.example.json` from its
                    // own directory, so an unbundled one means `init` cannot
                    // run — and the narrower filter would have passed.
                    .is_some_and(|x| matches!(x, "md" | "py" | "sh" | "json"))
                {
                    let rel = path
                        .strip_prefix(&root)
                        .expect("under repo root")
                        .to_string_lossy()
                        .replace('\\', "/");
                    if !bundled.contains(&rel) {
                        missing.push(rel);
                    }
                }
            }
        }

        missing.sort();
        assert!(
            missing.is_empty(),
            "skill files exist in-repo but are not bundled, so `locus init` will \
             install a partially-working skill: {missing:?}"
        );
    }

    /// The Algorithm now ships down two paths — `algorithm/v2.0.md` for the
    /// binary install, and `skills/locus-algorithm/SKILL.md` for the plugin.
    /// Two copies is one copy too many, so the skill is generated from the
    /// spec and this test is what makes the generation non-optional: edit the
    /// spec, forget to re-run the generator, and the build fails here rather
    /// than shipping two Locuses that disagree about their own Algorithm.
    #[test]
    fn locus_algorithm_skill_body_matches_the_algorithm() {
        let root = repo_root();
        let spec = std::fs::read_to_string(root.join("algorithm").join(locus_core::ALGORITHM_FILE))
            .expect("Algorithm spec missing");
        let skill = std::fs::read_to_string(root.join("skills/locus-algorithm/SKILL.md"))
            .expect("locus-algorithm SKILL.md missing — run scripts/gen-algorithm-skill.sh");

        assert!(
            skill.ends_with(&spec),
            "skills/locus-algorithm/SKILL.md is not algorithm/{} plus frontmatter. \
             Run scripts/gen-algorithm-skill.sh.",
            locus_core::ALGORITHM_FILE
        );
    }

    /// The dispatcher is injected next to every single prompt, so its size is
    /// paid on every turn of every session. One kilobyte is the budget the
    /// design set; without a test, prose grows and nobody notices the bill.
    #[test]
    fn dispatcher_payload_stays_under_one_kilobyte() {
        let payload =
            std::fs::read(repo_root().join("crates/locus-cli/src/commands/dispatcher.txt"))
                .expect("dispatcher.txt missing");

        assert!(
            payload.len() < 1024,
            "dispatcher.txt is {} bytes; the budget is 1024 because this text is \
             injected on every turn",
            payload.len()
        );
    }

    /// `agents` in a plugin manifest *replaces* the default `./agents/` scan
    /// rather than extending it, and it only accepts file paths — so listing
    /// the directory is invalid and listing the files invites drift the moment
    /// someone adds an agent. Omitting the key is the correct answer, and this
    /// test states why so nobody "fixes" it back.
    #[test]
    fn plugin_manifest_omits_agents_so_the_default_scan_applies() {
        let manifest = std::fs::read_to_string(repo_root().join(".claude-plugin/plugin.json"))
            .expect("plugin manifest missing");
        let parsed: serde_json::Value =
            serde_json::from_str(&manifest).expect("plugin.json is not valid JSON");

        assert!(
            parsed.get("agents").is_none(),
            "plugin.json declares `agents`, which replaces the default ./agents/ \
             scan — every agent not listed disappears silently"
        );

        // `hooks/hooks.json` is loaded automatically, exactly like ./skills/
        // and ./agents/. Naming it in the manifest as well loads it twice and
        // the plugin fails with `hook-load-failed` — while
        // `claude plugin validate --strict` still passes. The only place that
        // failure surfaces is the system/init event, so this test stands in
        // for a check the validator does not perform.
        assert!(
            parsed.get("hooks").is_none(),
            "plugin.json declares `hooks`; hooks/hooks.json is already loaded \
             automatically, so this registers it twice and the whole plugin \
             fails to load its hooks. Verified against claude 2.1.263 — \
             `validate --strict` does not catch it."
        );
    }

    /// The marketplace entry must source the plugin from a path that is
    /// actually in the repository. `dist/plugin` is the obvious-looking answer
    /// and it is wrong: `/dist` is gitignored, so `claude plugin marketplace
    /// add devergehq/locus` — which fetches a git ref — resolves the source to
    /// a directory that does not exist for anyone who has not already cloned
    /// *and* run `scripts/build-plugin.sh`. That is precisely the audience the
    /// marketplace manifest exists to serve.
    #[test]
    fn marketplace_entry_sources_a_committed_path_not_the_build_output() {
        let manifest = std::fs::read_to_string(repo_root().join(".claude-plugin/marketplace.json"))
            .expect("marketplace manifest missing");
        let parsed: serde_json::Value =
            serde_json::from_str(&manifest).expect("marketplace.json is not valid JSON");

        // `claude plugin install locus@locus` is <plugin>@<marketplace>; both
        // halves are pinned because the README documents that exact line.
        assert_eq!(parsed["name"], "locus", "marketplace name feeds `@locus`");

        let plugins = parsed["plugins"]
            .as_array()
            .expect("marketplace.json declares no plugins array");
        let entry = plugins
            .iter()
            .find(|p| p["name"] == "locus")
            .expect("no plugin entry named `locus`");

        // A relative path string is the only source type that resolves both
        // for `marketplace add /path/to/locus` and for `marketplace add
        // devergehq/locus`. A github source object would pin distribution to
        // GitHub and stop local development testing uncommitted work.
        let source = entry["source"]
            .as_str()
            .expect("source must be a relative path string");
        assert!(
            source.starts_with("./"),
            "source {source:?} must start with `./` — bare names require \
             metadata.pluginRoot, which claude.ai organization settings reject"
        );
        assert!(
            !source.contains("dist"),
            "source {source:?} points into the build output, which is \
             gitignored and therefore absent from every git-fetched copy"
        );

        // Version lives in plugin.json and nowhere else. Declaring it here too
        // means a release has to bump two files in step, and the day they
        // disagree the marketplace silently pins the stale one.
        assert!(
            entry.get("version").is_none(),
            "marketplace entry declares `version`; plugin.json already owns it"
        );

        // Plugins distributed through claude.ai organization settings are
        // rejected outright if they carry a top-level `bin/`. The repo root has
        // none — only `scripts/build-plugin.sh` creates one, inside
        // `dist/plugin`, which this entry deliberately does not point at.
        assert!(
            !repo_root().join("bin").exists(),
            "a top-level bin/ has appeared; plugins carrying one are rejected \
             during claude.ai organization-settings sync"
        );
    }

    /// Locus does not own Allele's MCP server, and declaring it collides with
    /// the registration every Allele user already has.
    ///
    /// The manifest carried an `mcpServers.allele` block for exactly one commit
    /// (`5b45c02`, DEV-579). It never worked: its command was
    /// `${user_config.alleleBinary}`, `pluginConfigs` is `{}` so that resolved
    /// to nothing, and the fallback was bare `allele` — which is on nobody's
    /// PATH, because the product ships as `Allele.app`, not a CLI. Every
    /// session showed `plugin:locus:allele ✘ ENOENT` next to the user's own
    /// working entry.
    ///
    /// Nothing was lost by removing it: no Rust in this repo has ever read
    /// `mcpServers`, and `~/.claude.json` has always been the canonical
    /// registration. Locus detects Allele — see `locus_core::vehicles` — and
    /// the README documents the one-line `claude mcp add` a user runs
    /// themselves. Re-adding the block would restore the collision.
    #[test]
    fn plugin_manifest_declares_no_mcp_servers() {
        let manifest = std::fs::read_to_string(repo_root().join(".claude-plugin/plugin.json"))
            .expect("plugin manifest missing");
        let parsed: serde_json::Value =
            serde_json::from_str(&manifest).expect("plugin.json is not valid JSON");

        assert!(
            parsed.get("mcpServers").is_none(),
            "plugin.json declares `mcpServers`; Allele owns its own MCP server and \
             the user's ~/.claude.json entry is canonical. Declaring it here shows up \
             as a second, broken `plugin:locus:allele` server on every session."
        );

        // The only reason `alleleBinary` existed was to fill in that command.
        // Leaving it behind would be a config knob that configures nothing —
        // and would still appear in the plugin's settings UI.
        let allele_binary = parsed.get("userConfig").and_then(|c| c.get("alleleBinary"));
        assert!(
            allele_binary.is_none(),
            "plugin.json still declares `userConfig.alleleBinary`; nothing reads it \
             now that `mcpServers` is gone"
        );
    }

    /// A dispatcher mode needs FOUR config sites and a brief, and missing any one
    /// of them fails late, differently, and a long way from the cause.
    ///
    /// This is not hypothetical. `workers/decide.md` shipped in v0.3.1 with a brief
    /// and nothing else — no trigger label, no `linear.modes` entry, no `traits`
    /// entry — so `D brief` on a decision child raised `KeyError: 'decide'` and
    /// `D label` answered `unknown label state`. The file was inert for a whole
    /// release and this suite was green throughout, because no test knew a mode is
    /// a tuple rather than a file.
    ///
    /// The four sites, and what each one breaks on its own:
    ///   `traits.<mode>`               — `cmd_brief` does `cfg["traits"][mode]`
    ///   `allele.orchestration.<mode>` — `SKILL.md` passes it to sessions_create
    ///   `modes.<mode>.trigger`        — `linear_triggers` indexes `labels[...]`
    ///   `modes.<mode>.working`        — what `D label` is handed at claim time
    #[test]
    fn every_dispatcher_mode_has_its_labels_traits_and_brief() {
        let root = repo_root();
        let raw = std::fs::read_to_string(root.join("skills/dispatcher/config.example.json"))
            .expect("config.example.json missing");
        let cfg: serde_json::Value =
            serde_json::from_str(&raw).expect("config.example.json is not valid JSON");

        let labels = cfg["linear"]["labels"].as_object().expect("linear.labels");
        let modes = cfg["linear"]["modes"].as_object().expect("linear.modes");
        let traits = cfg["traits"].as_object().expect("traits");
        let orchestration = cfg["allele"]["orchestration"]
            .as_object()
            .expect("allele.orchestration");

        let mut broken = Vec::new();
        for (mode, spec) in modes {
            for field in ["trigger", "working"] {
                let name = spec[field].as_str().unwrap_or_default();
                if !labels.contains_key(name) {
                    broken.push(format!(
                        "modes.{mode}.{field} names label `{name}`, absent from linear.labels"
                    ));
                }
            }
            if !traits.contains_key(mode) {
                broken.push(format!(
                    "traits.{mode} missing — `D brief` raises KeyError: '{mode}'"
                ));
            }
            if !orchestration.contains_key(mode) {
                broken.push(format!(
                    "allele.orchestration.{mode} missing — nothing to pass at sessions_create"
                ));
            }
        }

        // Every mode with traits needs a brief for `D brief` to name. `review` is
        // deliberately in `traits` and NOT in `modes`: it is raised by a GitHub
        // review request, never by a Linear label, so it has no trigger to name.
        for mode in traits.keys() {
            if !root
                .join(format!("skills/dispatcher/workers/{mode}.md"))
                .is_file()
            {
                broken.push(format!(
                    "traits.{mode} has no workers/{mode}.md for `D brief` to name"
                ));
            }
        }

        assert!(
            broken.is_empty(),
            "config.example.json describes a mode it cannot dispatch. Each of these fails at \
             run time, in a different command, with an error that does not name this file:\n  {}",
            broken.join("\n  ")
        );

        // A label no mode triggers and no brief sets is an id `init` mints for
        // nothing, and a reader cannot tell a retired label from forgotten wiring.
        let reachable: std::collections::HashSet<&str> = modes
            .values()
            .flat_map(|m| [m["trigger"].as_str(), m["working"].as_str()])
            .flatten()
            // Set by a worker or a coordinator rather than by the poller, so they
            // belong to no mode: `D label <KEY> <state>` writes these.
            .chain(["needs-input", "blocked", "done", "failed"])
            .collect();
        let orphans: Vec<&String> = labels
            .keys()
            .filter(|k| !reachable.contains(k.as_str()))
            .collect();
        assert!(
            orphans.is_empty(),
            "linear.labels entries that no mode triggers and no brief sets: {orphans:?}"
        );
    }

    /// Routing to the coordinator protocol, pinned in both directions.
    ///
    /// `stack.v2.md` shipped complete and inert for a release because the two
    /// files that send a coordinator anywhere still named `stack.md`. Nothing
    /// caught it: both files parse, both are bundled, and the wrong protocol is
    /// still a valid document. A grep is the only detector this failure has.
    ///
    /// The `stack.md` half pins a redirect. Keeping a short signpost costs
    /// nothing and catches anything still looking for the filename the old
    /// instructions named — a worker running from a cached copy of an older
    /// brief, most often.
    ///
    /// A second reason is real but narrower than an earlier version of this
    /// comment claimed, and the overstatement is worth recording because it
    /// read as verified: `update_content.rs:127` never removes files from
    /// `~/.locus/`, and the dispatcher IS carried by that path (a sync into a
    /// fresh LOCUS_HOME produces `skills/dispatcher/workers/stack.md`). So a
    /// machine that has synced with this file bundled would keep the superseded
    /// protocol forever after a deletion. That is LATENT: v0.3.1 shipped the
    /// dispatcher, and no LOCUS_HOME had been synced since, so the stranding did
    /// not yet exist anywhere. The mechanism was checked; whether it applied to
    /// these files was not.
    #[test]
    fn coordinator_routing_names_the_live_protocol() {
        let root = repo_root().join("skills/dispatcher");
        let workers = root.join("workers");

        for (file, what) in [
            (root.join("SKILL.md"), "SKILL.md's fan-out section"),
            (workers.join("implement.md"), "implement.md step 0"),
        ] {
            let text = std::fs::read_to_string(&file).expect("routing file missing");
            assert!(
                text.contains("stack.v2.md"),
                "{what} does not name stack.v2.md, so a coordinator is routed to a protocol \
                 that is not the live one — exactly how stack.v2.md shipped inert."
            );
        }

        let v2 = std::fs::read_to_string(workers.join("stack.v2.md")).expect("stack.v2.md missing");
        let head: String = v2.lines().take(20).collect::<Vec<_>>().join("\n");
        assert!(
            !head.contains("UNVALIDATED") && !head.contains("NOT IN USE"),
            "stack.v2.md still opens with the banner saying nothing routes to it, while \
             implement.md and SKILL.md both do. One of the two is lying to its reader."
        );

        let v1 = std::fs::read_to_string(workers.join("stack.md")).expect(
            "workers/stack.md is gone. It must stay as a signpost: update_content.rs never \
             removes files from ~/.locus/, so deleting it here leaves the superseded protocol \
             on every existing install instead of replacing it.",
        );
        assert!(
            v1.contains("stack.v2.md") && v1.len() < 4000,
            "workers/stack.md should be a short signpost pointing at stack.v2.md, not a \
             second coordinator protocol ({} bytes)",
            v1.len()
        );
    }
}
