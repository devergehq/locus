//! Locus CLI — the entry point for the Locus agentic workflow framework.

mod commands;
mod output;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "locus",
    about = "Agentic AI workflow execution framework",
    version,
    propagate_version = true
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialise a new Locus installation.
    ///
    /// Scaffolds ~/.locus/ with default configuration, detects your
    /// environment (shell, editor, git config), and sets up the
    /// data directory for persistent memory.
    Init {
        /// Skip environment detection and use bare defaults.
        #[arg(long)]
        bare: bool,
    },

    /// Validate the Locus installation.
    ///
    /// Checks config, platform adapters, directory structure,
    /// and reports any issues.
    Doctor,

    /// Manage platform adapters.
    Platform {
        #[command(subcommand)]
        command: PlatformCommands,
    },

    /// Browse and inspect available skills.
    Skill {
        #[command(subcommand)]
        command: SkillCommands,
    },
}

#[derive(Subcommand)]
enum PlatformCommands {
    /// List all supported platforms and their status.
    List,

    /// Add a platform adapter and generate its configuration.
    Add {
        /// Platform to add (e.g., "opencode", "claude-code").
        platform: String,
    },

    /// Remove a platform adapter.
    Remove {
        /// Platform to remove.
        platform: String,
    },
}

#[derive(Subcommand)]
enum SkillCommands {
    /// List all available skills.
    List,

    /// Show detailed info about a specific skill.
    Info {
        /// Skill identifier (e.g., "research", "council").
        skill: String,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Init { bare } => commands::init::run(bare),
        Commands::Doctor => commands::doctor::run(),
        Commands::Platform { command } => match command {
            PlatformCommands::List => commands::platform::list(),
            PlatformCommands::Add { platform } => commands::platform::add(&platform),
            PlatformCommands::Remove { platform } => commands::platform::remove(&platform),
        },
        Commands::Skill { command } => match command {
            SkillCommands::List => commands::skill::list(),
            SkillCommands::Info { skill } => commands::skill::info(&skill),
        },
    };

    if let Err(e) = result {
        output::error(&e.to_string());
        std::process::exit(1);
    }
}
