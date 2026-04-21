//! `locus init` — scaffold a new Locus installation.

use std::fs;
use std::path::PathBuf;

use locus_core::config::{
    AlgorithmConfig, InferenceConfig, LocusConfig, NotificationConfig, PathConfig, SkillConfig,
};
use locus_core::platform::Platform;
use locus_core::LocusError;

use crate::output;

/// Run the init command.
pub fn run(bare: bool) -> Result<(), LocusError> {
    output::print_header();
    output::section("Initialising Locus");

    let home = resolve_locus_home()?;

    // Check if already initialised.
    let config_path = home.join("locus.yaml");
    if config_path.exists() {
        output::warn(&format!(
            "Locus is already initialised at {}",
            home.display()
        ));
        output::info("Run `locus doctor` to validate your installation.");
        return Ok(());
    }

    // Create directory structure.
    create_directories(&home)?;

    // Detect environment.
    let detected = if bare {
        output::info("Bare mode — skipping environment detection.");
        DetectedEnv::default()
    } else {
        detect_environment()
    };

    // Detect installed platforms.
    let platforms = detect_platforms();
    if platforms.is_empty() {
        output::warn("No supported AI coding platforms detected.");
        output::info("You can add one later with `locus platform add <platform>`.");
    } else {
        for p in &platforms {
            output::success(&format!("Detected {}", p.display_name()));
        }
    }

    // Generate default config.
    let config = build_default_config(platforms, &detected);
    let yaml = config.to_yaml()?;
    fs::write(&config_path, &yaml).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write config: {}", e),
        path: config_path.clone(),
    })?;
    output::success(&format!("Created {}", config_path.display()));

    // Summary.
    output::section("Ready");
    output::info(&format!("Home:   {}", home.display()));
    output::info(&format!("Data:   {}", home.join("data").display()));
    output::info(&format!("Config: {}", config_path.display()));
    println!();
    output::info("Next steps:");
    if config.platforms.is_empty() {
        output::info("  locus platform add opencode   Add a platform adapter");
    }
    output::info("  locus doctor                  Validate installation");
    println!();

    Ok(())
}

/// Resolve the Locus home directory.
fn resolve_locus_home() -> Result<PathBuf, LocusError> {
    if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        return Ok(PathBuf::from(env_home));
    }

    dirs::home_dir()
        .map(|h| h.join(".locus"))
        .ok_or_else(|| LocusError::Config {
            message: "Could not determine home directory".into(),
            path: None,
        })
}

/// Create the Locus directory structure and install content.
fn create_directories(home: &PathBuf) -> Result<(), LocusError> {
    let dirs = [
        home.to_path_buf(),
        home.join("algorithm"),
        home.join("skills"),
        home.join("agents"),
        home.join("protocols"),
        home.join("data"),
        home.join("data/memory"),
        home.join("data/memory/work"),
        home.join("data/memory/learning"),
        home.join("data/memory/research"),
        home.join("data/memory/state"),
        home.join("data/projects"),
        home.join("data/context-packs"),
        home.join("data/skill-customizations"),
    ];

    for dir in &dirs {
        fs::create_dir_all(dir).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to create directory: {}", e),
            path: dir.clone(),
        })?;
    }

    // Install bundled content (algorithm, skills, agents, protocols).
    install_bundled_content(home)?;

    output::success(&format!(
        "Created directory structure at {}",
        home.display()
    ));
    Ok(())
}

/// Install the bundled algorithm, skills, agents, and protocols.
///
/// Content is embedded at compile time from the repo source directories.
fn install_bundled_content(home: &PathBuf) -> Result<(), LocusError> {
    // Algorithm
    write_bundled(
        home,
        "algorithm/v1.1.md",
        include_str!("../../../../algorithm/v1.1.md"),
    )?;

    // Skills — top-level SKILL.md files
    let skills: &[(&str, &str)] = &[
        (
            "skills/research/SKILL.md",
            include_str!("../../../../skills/research/SKILL.md"),
        ),
        (
            "skills/research/UrlVerificationProtocol.md",
            include_str!("../../../../skills/research/UrlVerificationProtocol.md"),
        ),
        (
            "skills/research/Workflows/Standard.md",
            include_str!("../../../../skills/research/Workflows/Standard.md"),
        ),
        (
            "skills/research/Workflows/Interview.md",
            include_str!("../../../../skills/research/Workflows/Interview.md"),
        ),
        (
            "skills/research/Workflows/ExtractAlpha.md",
            include_str!("../../../../skills/research/Workflows/ExtractAlpha.md"),
        ),
        (
            "skills/research/Workflows/Quick.md",
            include_str!("../../../../skills/research/Workflows/Quick.md"),
        ),
        (
            "skills/research/Workflows/Extensive.md",
            include_str!("../../../../skills/research/Workflows/Extensive.md"),
        ),
        (
            "skills/research/Workflows/Deep.md",
            include_str!("../../../../skills/research/Workflows/Deep.md"),
        ),
        (
            "skills/research/Workflows/ExtractKnowledge.md",
            include_str!("../../../../skills/research/Workflows/ExtractKnowledge.md"),
        ),
        (
            "skills/research/Workflows/YoutubeExtraction.md",
            include_str!("../../../../skills/research/Workflows/YoutubeExtraction.md"),
        ),
        (
            "skills/research/Workflows/WebScraping.md",
            include_str!("../../../../skills/research/Workflows/WebScraping.md"),
        ),
        (
            "skills/research/Workflows/Enhance.md",
            include_str!("../../../../skills/research/Workflows/Enhance.md"),
        ),
        (
            "skills/research/Workflows/Retrieve.md",
            include_str!("../../../../skills/research/Workflows/Retrieve.md"),
        ),
        (
            "skills/first-principles/SKILL.md",
            include_str!("../../../../skills/first-principles/SKILL.md"),
        ),
        (
            "skills/first-principles/Workflows/Decompose.md",
            include_str!("../../../../skills/first-principles/Workflows/Decompose.md"),
        ),
        (
            "skills/iterative-depth/SKILL.md",
            include_str!("../../../../skills/iterative-depth/SKILL.md"),
        ),
        (
            "skills/iterative-depth/TheLenses.md",
            include_str!("../../../../skills/iterative-depth/TheLenses.md"),
        ),
        (
            "skills/iterative-depth/ScientificFoundation.md",
            include_str!("../../../../skills/iterative-depth/ScientificFoundation.md"),
        ),
        (
            "skills/iterative-depth/Workflows/Explore.md",
            include_str!("../../../../skills/iterative-depth/Workflows/Explore.md"),
        ),
        (
            "skills/council/SKILL.md",
            include_str!("../../../../skills/council/SKILL.md"),
        ),
        (
            "skills/council/CouncilMembers.md",
            include_str!("../../../../skills/council/CouncilMembers.md"),
        ),
        (
            "skills/council/RoundStructure.md",
            include_str!("../../../../skills/council/RoundStructure.md"),
        ),
        (
            "skills/council/OutputFormat.md",
            include_str!("../../../../skills/council/OutputFormat.md"),
        ),
        (
            "skills/council/Workflows/Debate.md",
            include_str!("../../../../skills/council/Workflows/Debate.md"),
        ),
        (
            "skills/council/Workflows/Quick.md",
            include_str!("../../../../skills/council/Workflows/Quick.md"),
        ),
        (
            "skills/red-team/SKILL.md",
            include_str!("../../../../skills/red-team/SKILL.md"),
        ),
        (
            "skills/red-team/Philosophy.md",
            include_str!("../../../../skills/red-team/Philosophy.md"),
        ),
        (
            "skills/red-team/Integration.md",
            include_str!("../../../../skills/red-team/Integration.md"),
        ),
        (
            "skills/red-team/Workflows/ParallelAnalysis.md",
            include_str!("../../../../skills/red-team/Workflows/ParallelAnalysis.md"),
        ),
        (
            "skills/red-team/Workflows/AdversarialValidation.md",
            include_str!("../../../../skills/red-team/Workflows/AdversarialValidation.md"),
        ),
        (
            "skills/creative/SKILL.md",
            include_str!("../../../../skills/creative/SKILL.md"),
        ),
        (
            "skills/creative/Principles.md",
            include_str!("../../../../skills/creative/Principles.md"),
        ),
        (
            "skills/creative/Examples.md",
            include_str!("../../../../skills/creative/Examples.md"),
        ),
        (
            "skills/creative/Templates.md",
            include_str!("../../../../skills/creative/Templates.md"),
        ),
        (
            "skills/creative/ResearchFoundation.md",
            include_str!("../../../../skills/creative/ResearchFoundation.md"),
        ),
        (
            "skills/science/SKILL.md",
            include_str!("../../../../skills/science/SKILL.md"),
        ),
        (
            "skills/science/METHODOLOGY.md",
            include_str!("../../../../skills/science/METHODOLOGY.md"),
        ),
        (
            "skills/science/Protocol.md",
            include_str!("../../../../skills/science/Protocol.md"),
        ),
        (
            "skills/science/Templates.md",
            include_str!("../../../../skills/science/Templates.md"),
        ),
        (
            "skills/science/Examples.md",
            include_str!("../../../../skills/science/Examples.md"),
        ),
        (
            "skills/science/Workflows/FullCycle.md",
            include_str!("../../../../skills/science/Workflows/FullCycle.md"),
        ),
        (
            "skills/science/Workflows/QuickDiagnosis.md",
            include_str!("../../../../skills/science/Workflows/QuickDiagnosis.md"),
        ),
        (
            "skills/science/Workflows/DefineGoal.md",
            include_str!("../../../../skills/science/Workflows/DefineGoal.md"),
        ),
        (
            "skills/extract-wisdom/SKILL.md",
            include_str!("../../../../skills/extract-wisdom/SKILL.md"),
        ),
        (
            "skills/documents/SKILL.md",
            include_str!("../../../../skills/documents/SKILL.md"),
        ),
        (
            "skills/security/SKILL.md",
            include_str!("../../../../skills/security/SKILL.md"),
        ),
        (
            "skills/media/SKILL.md",
            include_str!("../../../../skills/media/SKILL.md"),
        ),
        (
            "skills/media/Workflows/ImageGeneration.md",
            include_str!("../../../../skills/media/Workflows/ImageGeneration.md"),
        ),
        (
            "skills/parser/SKILL.md",
            include_str!("../../../../skills/parser/SKILL.md"),
        ),
        (
            "skills/delegation/SKILL.md",
            include_str!("../../../../skills/delegation/SKILL.md"),
        ),
    ];

    for (path, content) in skills {
        write_bundled(home, path, content)?;
    }

    // Agents — traits data + archetype files
    let agents: &[(&str, &str)] = &[
        (
            "agents/traits.yaml",
            include_str!("../../../../agents/traits.yaml"),
        ),
        (
            "agents/architect.md",
            include_str!("../../../../agents/architect.md"),
        ),
        (
            "agents/engineer.md",
            include_str!("../../../../agents/engineer.md"),
        ),
        (
            "agents/researcher.md",
            include_str!("../../../../agents/researcher.md"),
        ),
        (
            "agents/security.md",
            include_str!("../../../../agents/security.md"),
        ),
        (
            "agents/designer.md",
            include_str!("../../../../agents/designer.md"),
        ),
        (
            "agents/qa-tester.md",
            include_str!("../../../../agents/qa-tester.md"),
        ),
        (
            "agents/artist.md",
            include_str!("../../../../agents/artist.md"),
        ),
        (
            "agents/ui-reviewer.md",
            include_str!("../../../../agents/ui-reviewer.md"),
        ),
        (
            "agents/pentester.md",
            include_str!("../../../../agents/pentester.md"),
        ),
        (
            "agents/plan-agent.md",
            include_str!("../../../../agents/plan-agent.md"),
        ),
        (
            "agents/algorithm-agent.md",
            include_str!("../../../../agents/algorithm-agent.md"),
        ),
        (
            "agents/academic-researcher.md",
            include_str!("../../../../agents/academic-researcher.md"),
        ),
        (
            "agents/investigative-researcher.md",
            include_str!("../../../../agents/investigative-researcher.md"),
        ),
        (
            "agents/contrarian-researcher.md",
            include_str!("../../../../agents/contrarian-researcher.md"),
        ),
        (
            "agents/multi-angle-researcher.md",
            include_str!("../../../../agents/multi-angle-researcher.md"),
        ),
        (
            "agents/deep-investigation-researcher.md",
            include_str!("../../../../agents/deep-investigation-researcher.md"),
        ),
    ];

    for (path, content) in agents {
        write_bundled(home, path, content)?;
    }

    // Protocols
    let protocols: &[(&str, &str)] = &[
        (
            "protocols/context-management.md",
            include_str!("../../../../protocols/context-management.md"),
        ),
        (
            "protocols/degradation.md",
            include_str!("../../../../protocols/degradation.md"),
        ),
        (
            "protocols/memory-schema.md",
            include_str!("../../../../protocols/memory-schema.md"),
        ),
    ];

    for (path, content) in protocols {
        write_bundled(home, path, content)?;
    }

    Ok(())
}

/// Write a bundled file to the Locus home directory.
fn write_bundled(home: &PathBuf, relative_path: &str, content: &str) -> Result<(), LocusError> {
    let target = home.join(relative_path);
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to create directory: {}", e),
            path: parent.to_path_buf(),
        })?;
    }
    fs::write(&target, content).map_err(|e| LocusError::Filesystem {
        message: format!("Failed to write file: {}", e),
        path: target,
    })
}

/// Detected environment information.
#[derive(Default)]
#[allow(dead_code)]
struct DetectedEnv {
    shell: Option<String>,
    editor: Option<String>,
    git_user: Option<String>,
    git_email: Option<String>,
}

/// Detect the user's development environment.
fn detect_environment() -> DetectedEnv {
    let shell = std::env::var("SHELL").ok().map(|s| {
        // Extract just the shell name from the path.
        s.rsplit('/').next().unwrap_or(&s).to_string()
    });

    let editor = std::env::var("EDITOR")
        .or_else(|_| std::env::var("VISUAL"))
        .ok();

    let git_user = std::process::Command::new("git")
        .args(["config", "--global", "user.name"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        });

    let git_email = std::process::Command::new("git")
        .args(["config", "--global", "user.email"])
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                String::from_utf8(o.stdout)
                    .ok()
                    .map(|s| s.trim().to_string())
            } else {
                None
            }
        });

    if let Some(ref shell) = shell {
        output::info(&format!("Shell:  {}", shell));
    }
    if let Some(ref editor) = editor {
        output::info(&format!("Editor: {}", editor));
    }
    if let Some(ref user) = git_user {
        output::info(&format!("Git:    {}", user));
    }

    DetectedEnv {
        shell,
        editor,
        git_user,
        git_email,
    }
}

/// Detect which supported platforms are installed.
fn detect_platforms() -> Vec<Platform> {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return Vec::new(),
    };

    let mut found = Vec::new();
    for platform in Platform::all() {
        let config_dir = home.join(platform.config_dir_name());
        if config_dir.exists() {
            // Also check if the CLI binary is available.
            let cli_available = std::process::Command::new("which")
                .arg(platform.cli_command())
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false);

            if cli_available {
                found.push(*platform);
            }
        }
    }

    found
}

/// Build a default LocusConfig from detected environment.
fn build_default_config(platforms: Vec<Platform>, _env: &DetectedEnv) -> LocusConfig {
    LocusConfig {
        platforms,
        algorithm: AlgorithmConfig::default(),
        skills: SkillConfig::default(),
        notifications: NotificationConfig::default(),
        inference: InferenceConfig::default(),
        paths: PathConfig::default(),
        platform_overrides: std::collections::HashMap::new(),
    }
}
