//! `locus agent ...` — trait-based agent composition.

use std::io::Write;
use std::path::PathBuf;

use locus_core::{LocusError, Traits};

use crate::output;

/// Output format for `locus agent compose`.
#[derive(Debug, Clone, Copy, clap::ValueEnum)]
pub enum ComposeOutput {
    /// Emit the composed prompt string only (default).
    Prompt,
    /// Emit a structured JSON object with role, traits, keywords, prompt.
    Json,
}

/// Run the compose subcommand.
///
/// Reads `~/.locus/agents/traits.yaml` (or `$LOCUS_HOME/agents/traits.yaml`),
/// composes an agent from the supplied trait IDs, and emits either the
/// composed prompt text (default) or a JSON object.
pub fn compose(
    traits_csv: &str,
    role: Option<String>,
    task: Option<String>,
    output_mode: ComposeOutput,
) -> Result<(), LocusError> {
    let traits_path = resolve_traits_path()?;
    let traits = Traits::from_file(&traits_path)?;

    let trait_ids: Vec<&str> = traits_csv
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if trait_ids.is_empty() {
        return Err(LocusError::Config {
            message: "No traits supplied. Use --traits \"traitA,traitB,...\"".into(),
            path: None,
        });
    }

    let composed = traits.compose(&trait_ids, role.as_deref(), task.as_deref())?;

    match output_mode {
        ComposeOutput::Prompt => {
            let mut stdout = std::io::stdout().lock();
            stdout.write_all(composed.prompt.as_bytes()).ok();
            stdout.write_all(b"\n").ok();
        }
        ComposeOutput::Json => {
            let json = serde_json::to_string_pretty(&composed).map_err(|e| LocusError::Config {
                message: format!("Failed to serialise composed agent: {}", e),
                path: None,
            })?;
            let mut stdout = std::io::stdout().lock();
            stdout.write_all(json.as_bytes()).ok();
            stdout.write_all(b"\n").ok();
        }
    }

    Ok(())
}

/// List available traits across all three axes.
pub fn list_traits() -> Result<(), LocusError> {
    output::print_header();
    let traits_path = resolve_traits_path()?;
    let traits = Traits::from_file(&traits_path)?;

    output::section("Expertise");
    for (id, t) in &traits.expertise {
        output::list_item(id, &t.description);
    }

    output::section("Stance");
    for (id, t) in &traits.stance {
        output::list_item(id, &t.description);
    }

    output::section("Approach");
    for (id, t) in &traits.approach {
        output::list_item(id, &t.description);
    }

    println!();
    Ok(())
}

fn resolve_traits_path() -> Result<PathBuf, LocusError> {
    let home = if let Ok(env_home) = std::env::var("LOCUS_HOME") {
        PathBuf::from(env_home)
    } else {
        dirs::home_dir()
            .map(|h| h.join(".locus"))
            .ok_or_else(|| LocusError::Config {
                message: "Could not determine home directory".into(),
                path: None,
            })?
    };
    Ok(home.join("agents").join("traits.yaml"))
}
