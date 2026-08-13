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
            "algorithm/v1.1.md".into(),
            include_str!("../../../algorithm/v1.1.md"),
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

    #[test]
    fn every_repo_skill_is_bundled() {
        let bundled = bundled_paths();
        let dir = repo_root().join("skills");

        let missing: Vec<String> = std::fs::read_dir(&dir)
            .expect("skills dir")
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.join("SKILL.md").is_file())
            .filter_map(|p| {
                let rel = format!("skills/{}/SKILL.md", p.file_name()?.to_str()?);
                (!bundled.contains(&rel)).then_some(rel)
            })
            .collect();

        assert!(missing.is_empty(), "skills in-repo but not bundled: {missing:?}");
    }
}
