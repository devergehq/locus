//! `locus skill` — browse and inspect available skills.

use locus_core::LocusError;

use crate::output;

/// List all available skills.
pub fn list() -> Result<(), LocusError> {
    output::print_header();
    output::section("Available Skills");

    // TODO: Phase 3 — load skills from ~/.locus/skills/ directory.
    // For now, show the curated core skill list that will be implemented.
    output::info("Skills will be available after Phase 3 (Algorithm + Core Skills).");
    output::info("The following core skills are planned:");
    println!();

    let planned_skills = [
        (
            "research",
            "Comprehensive research with quick/standard/extensive/deep modes",
        ),
        (
            "thinking",
            "Multi-mode analytical thinking — first principles, iterative depth",
        ),
        (
            "council",
            "Multi-agent debate with structured rounds and synthesis",
        ),
        (
            "red-team",
            "Adversarial analysis to find weaknesses and fatal flaws",
        ),
        (
            "security",
            "Security assessment — recon, web testing, prompt injection",
        ),
        (
            "browser",
            "Browser automation and visual verification via headless Chrome",
        ),
        (
            "documents",
            "Read, write, convert documents — PDF, DOCX, XLSX, PPTX",
        ),
        (
            "media",
            "Visual content creation — diagrams, illustrations, infographics",
        ),
        (
            "parsing",
            "Extract structured data from URLs, files, and transcripts",
        ),
    ];

    for (id, description) in &planned_skills {
        output::list_item(id, description);
    }

    println!();
    output::info(&format!("{} core skills planned.", planned_skills.len()));
    println!();

    Ok(())
}

/// Show detailed info about a specific skill.
pub fn info(skill: &str) -> Result<(), LocusError> {
    output::print_header();
    output::section(&format!("Skill: {}", skill));

    // TODO: Phase 3 — load skill definition from SKILL.md.
    output::info("Skill details will be available after Phase 3.");
    output::info(&format!(
        "Will load from: ~/.locus/skills/{}/SKILL.md",
        skill
    ));

    println!();
    Ok(())
}
