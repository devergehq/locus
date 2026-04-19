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

    /// Show a dashboard of the current Locus installation.
    ///
    /// Prints version, active platform, installed skill count,
    /// data directory size, last sync timestamp, and doctor findings.
    Status,

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

    /// Synchronise user data between machines via git.
    ///
    /// Commits local changes and pushes/pulls from the remote.
    /// Use --init to set up the data directory as a git repo.
    Sync {
        /// Initialise data dir as git repo with this remote URL.
        #[arg(long = "init")]
        init_remote: Option<String>,
    },

    /// Check for and install updates from GitHub releases.
    ///
    /// Downloads the latest release binary and replaces the current
    /// installation. Use --check to see if an update is available
    /// without installing.
    Upgrade {
        /// Check for updates without installing.
        #[arg(long)]
        check: bool,
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
        Commands::Status => commands::status::run(),
        Commands::Platform { command } => match command {
            PlatformCommands::List => commands::platform::list(),
            PlatformCommands::Add { platform } => commands::platform::add(&platform),
            PlatformCommands::Remove { platform } => commands::platform::remove(&platform),
        },
        Commands::Skill { command } => match command {
            SkillCommands::List => commands::skill::list(),
            SkillCommands::Info { skill } => commands::skill::info(&skill),
        },
        Commands::Sync { init_remote } => commands::sync::run(init_remote),
        Commands::Upgrade { check } => commands::upgrade::run(check),
    };

    if let Err(e) = result {
        output::error(&e.to_string());
        std::process::exit(1);
    }
}
