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
            bundled_content, on_disk,
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
                } else if path.extension().is_some_and(|x| x == "md") {
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
        let payload = std::fs::read(repo_root().join("hooks/dispatcher.txt"))
            .expect("hooks/dispatcher.txt missing");

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
}
