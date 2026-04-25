//! Locus CLI — the entry point for the Locus agentic workflow framework.

mod bundled;
mod commands;
mod output;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

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

    /// Update bundled content from the binary to ~/.locus/.
    ///
    /// Syncs algorithm, skills, agents, protocols, and scripts.
    /// Compares SHA-256 hashes and only overwrites files that changed.
    /// By default also regenerates platform adapter configs.
    UpdateContent {
        /// Skip regenerating platform adapter configs.
        #[arg(long)]
        skip_platforms: bool,
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

    /// Delegate bounded work to an external execution backend.
    Delegate {
        #[command(subcommand)]
        command: DelegateCommands,
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
enum DelegateCommands {
    /// Run a read-only delegated task through a backend such as OpenCode.
    Run {
        /// Backend to use for execution.
        #[arg(long, value_enum)]
        backend: commands::delegate::DelegateBackendArg,

        /// Broad category of delegated work.
        #[arg(long, value_enum)]
        task_kind: commands::delegate::DelegateTaskKindArg,

        /// Provider/model identifier, e.g. openai/gpt-5.5.
        ///
        /// Optional when `delegation.defaults.<backend>.<task_kind>.model` is
        /// set in `~/.locus/locus.yaml`. The CLI flag wins when both are set.
        #[arg(long)]
        model: Option<String>,

        /// Workspace directory for the delegated backend.
        #[arg(long)]
        dir: PathBuf,

        /// Task prompt passed to the delegated backend.
        #[arg(long)]
        prompt: String,

        /// Optional backend agent/profile name.
        #[arg(long)]
        agent: Option<String>,

        /// Optional provider-specific reasoning variant.
        #[arg(long)]
        variant: Option<String>,

        /// Context file attached to the delegated request.
        #[arg(long = "context-file")]
        context_files: Vec<PathBuf>,

        /// Directory where raw backend artifacts are written.
        #[arg(long)]
        artifact_dir: Option<PathBuf>,

        /// Maximum execution time in seconds. Default 1200 (20 minutes).
        #[arg(long, default_value_t = 1200)]
        timeout_seconds: u64,

        /// Print the request JSON without invoking the backend.
        #[arg(long)]
        dry_run: bool,

        /// Output mode.
        #[arg(long, value_enum, default_value_t = commands::delegate::DelegateOutput::Json)]
        output: commands::delegate::DelegateOutput,

        /// Execution mode for the spawned session. `native` (default) skips
        /// the Locus Algorithm in the delegated session; `algorithmic` loads
        /// it. Almost always `native` — the orchestrator is here, not there.
        #[arg(long, value_enum, default_value_t = commands::delegate::ExecutionModeArg::Native)]
        mode: commands::delegate::ExecutionModeArg,
    },

    /// List existing delegation artifact directories.
    Ls {
        /// Override the delegations root directory.
        #[arg(long)]
        root: Option<PathBuf>,

        /// Output mode.
        #[arg(long, value_enum, default_value_t = commands::delegate::DelegateOutput::Human)]
        output: commands::delegate::DelegateOutput,
    },

    /// Prune delegation artifact directories. Dry-run unless --apply is passed.
    Prune {
        /// Only prune delegations older than this duration (e.g. 7d, 12h, 30m).
        #[arg(long)]
        older_than: Option<String>,

        /// Prune every delegation. Mutually exclusive with --older-than.
        #[arg(long)]
        all: bool,

        /// Actually delete (without this flag, prune is a dry-run).
        #[arg(long)]
        apply: bool,

        /// Keep stdout/stderr artifacts; only delete opencode-data and other files.
        #[arg(long)]
        keep_stdout: bool,

        /// Override the delegations root directory.
        #[arg(long)]
        root: Option<PathBuf>,

        /// Output mode.
        #[arg(long, value_enum, default_value_t = commands::delegate::DelegateOutput::Human)]
        output: commands::delegate::DelegateOutput,
    },
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
        Commands::UpdateContent { skip_platforms } => {
            commands::update_content::run(skip_platforms)
        }
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
        Commands::Delegate { command } => match command {
            DelegateCommands::Run {
                backend,
                task_kind,
                model,
                dir,
                prompt,
                agent,
                variant,
                context_files,
                artifact_dir,
                timeout_seconds,
                dry_run,
                output,
                mode,
            } => commands::delegate::run(commands::delegate::RunArgs {
                backend,
                task_kind,
                model,
                dir,
                prompt,
                agent,
                variant,
                context_files,
                artifact_dir,
                timeout_seconds,
                dry_run,
                output,
                mode,
            }),
            DelegateCommands::Ls { root, output } => {
                commands::delegate::ls(commands::delegate::LsArgs { root, output })
            }
            DelegateCommands::Prune {
                older_than,
                all,
                apply,
                keep_stdout,
                root,
                output,
            } => commands::delegate::prune(commands::delegate::PruneArgs {
                older_than,
                all,
                apply,
                keep_stdout,
                root,
                output,
            }),
        },
    };

    if let Err(e) = result {
        output::error(&e.to_string());
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_delegate_run_command() {
        let cli = Cli::try_parse_from([
            "locus",
            "delegate",
            "run",
            "--backend",
            "opencode",
            "--task-kind",
            "research",
            "--model",
            "openai/gpt-5.5",
            "--dir",
            "/tmp/project",
            "--prompt",
            "Research this",
            "--dry-run",
        ])
        .unwrap();

        match cli.command {
            Commands::Delegate {
                command: DelegateCommands::Run { dry_run, model, .. },
            } => {
                assert!(dry_run);
                assert_eq!(model.as_deref(), Some("openai/gpt-5.5"));
            }
            _ => panic!("expected delegate run command"),
        }
    }

    #[test]
    fn parses_delegate_run_command_without_model() {
        let cli = Cli::try_parse_from([
            "locus",
            "delegate",
            "run",
            "--backend",
            "opencode",
            "--task-kind",
            "research",
            "--dir",
            "/tmp/project",
            "--prompt",
            "Research this",
            "--dry-run",
        ])
        .unwrap();

        match cli.command {
            Commands::Delegate {
                command: DelegateCommands::Run { model, .. },
            } => assert!(model.is_none()),
            _ => panic!("expected delegate run command"),
        }
    }

    #[test]
    fn parses_delegate_run_command_with_explicit_mode() {
        let cli = Cli::try_parse_from([
            "locus",
            "delegate",
            "run",
            "--backend",
            "opencode",
            "--task-kind",
            "research",
            "--dir",
            "/tmp/project",
            "--prompt",
            "Research this",
            "--mode",
            "algorithmic",
            "--dry-run",
        ])
        .unwrap();

        match cli.command {
            Commands::Delegate {
                command: DelegateCommands::Run { mode, .. },
            } => assert_eq!(mode, commands::delegate::ExecutionModeArg::Algorithmic),
            _ => panic!("expected delegate run command"),
        }
    }

    #[test]
    fn parses_delegate_run_command_defaults_to_native_mode() {
        let cli = Cli::try_parse_from([
            "locus",
            "delegate",
            "run",
            "--backend",
            "opencode",
            "--task-kind",
            "research",
            "--dir",
            "/tmp/project",
            "--prompt",
            "Research this",
            "--dry-run",
        ])
        .unwrap();

        match cli.command {
            Commands::Delegate {
                command: DelegateCommands::Run { mode, .. },
            } => assert_eq!(mode, commands::delegate::ExecutionModeArg::Native),
            _ => panic!("expected delegate run command"),
        }
    }
}
