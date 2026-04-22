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

    /// Platform hook event handler.
    ///
    /// Invoked by Claude Code (via settings.json hooks) and other platforms.
    /// Reads a JSON event envelope from stdin, dispatches to the relevant
    /// handler, and emits JSON on stdout per the platform's hook protocol.
    Hook {
        #[command(subcommand)]
        command: HookCommands,
    },

    /// Trait-based agent composition.
    ///
    /// Composes agent prompts from trait IDs defined in
    /// `~/.locus/agents/traits.yaml`. Used by skills (Council, RedTeam,
    /// IterativeDepth, Research) that spawn multiple trait-diverse agents.
    Agent {
        #[command(subcommand)]
        command: AgentCommands,
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

#[derive(Subcommand)]
enum AgentCommands {
    /// Compose an agent prompt from trait IDs.
    ///
    /// Example:
    ///   locus agent compose --traits "security,skeptical,thorough" \
    ///                       --role "Auth reviewer" \
    ///                       --task "Review the login flow"
    Compose {
        /// Comma-separated trait IDs (e.g., "security,skeptical,thorough").
        #[arg(long)]
        traits: String,

        /// Optional role statement ("You are <role>.").
        #[arg(long)]
        role: Option<String>,

        /// Optional task statement ("Your task: <task>").
        #[arg(long)]
        task: Option<String>,

        /// Output mode: prompt (default, plain text) or json (structured).
        #[arg(long, value_enum, default_value_t = commands::agent::ComposeOutput::Prompt)]
        output: commands::agent::ComposeOutput,
    },

    /// List all available traits across expertise / stance / approach axes.
    ListTraits,
}

#[derive(Subcommand)]
enum HookCommands {
    /// Fired when a new session starts.
    SessionStart,
    /// Fired when a session ends.
    SessionEnd,
    /// Fired before the context window is compacted.
    PreCompact,
    /// Fired when the user submits a new prompt.
    UserPromptSubmit,
    /// Fired before a tool is invoked.
    PreToolUse,
    /// Fired after a tool completes.
    PostToolUse,
    /// Fired when the AI produces a response (platform "Stop" event).
    Stop,
    /// Platform notification event (e.g., status updates).
    Notification,
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
        Commands::Hook { command } => {
            let kind = match command {
                HookCommands::SessionStart => commands::hook::HookEventKind::SessionStart,
                HookCommands::SessionEnd => commands::hook::HookEventKind::SessionEnd,
                HookCommands::PreCompact => commands::hook::HookEventKind::PreCompact,
                HookCommands::UserPromptSubmit => commands::hook::HookEventKind::UserPromptSubmit,
                HookCommands::PreToolUse => commands::hook::HookEventKind::PreToolUse,
                HookCommands::PostToolUse => commands::hook::HookEventKind::PostToolUse,
                HookCommands::Stop => commands::hook::HookEventKind::Stop,
                HookCommands::Notification => commands::hook::HookEventKind::Notification,
            };
            commands::hook::run(kind)
        }
        Commands::Agent { command } => match command {
            AgentCommands::Compose {
                traits,
                role,
                task,
                output,
            } => commands::agent::compose(&traits, role, task, output),
            AgentCommands::ListTraits => commands::agent::list_traits(),
        },
    };

    if let Err(e) = result {
        output::error(&e.to_string());
        std::process::exit(1);
    }
}
