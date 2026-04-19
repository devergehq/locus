# Locus upgrade command implementation

**Session ID:** ses_25a038eb0ffeFjCFEL8dy9m81e
**Created:** 4/19/2026, 11:44:37 PM
**Updated:** 4/19/2026, 11:47:27 PM

---

## User

I want to add a `locus upgrade` command that checks if the installed binary version matches the latest release on GitHub, and if not, downloads and replaces the binary. Think through how to approach this. 

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 4.5s)

I'll help you think through adding a `locus upgrade` command. Let me start by exploring the current codebase structure to understand how Locus is organized and how commands are implemented.

**Tool: bash**

**Input:**
```json
{
  "command": "pwd",
  "description": "Get current working directory"
}
```

**Output:**
```
/Users/patrickdorival/sites/clients/deverge/locus

```

**Tool: bash**

**Input:**
```json
{
  "command": "ls -la",
  "description": "List files in current directory"
}
```

**Output:**
```
total 48
drwxr-xr-x@ 12 patrickdorival  staff    384 19 Apr 21:17 .
drwxr-xr-x  10 patrickdorival  staff    320 19 Apr 21:13 ..
drwxr-xr-x@ 15 patrickdorival  staff    480 19 Apr 23:43 .git
-rw-r--r--@  1 patrickdorival  staff     19 19 Apr 21:18 .gitignore
drwxr-xr-x@  6 patrickdorival  staff    192 19 Apr 21:40 agents
drwxr-xr-x@  3 patrickdorival  staff     96 19 Apr 21:38 algorithm
-rw-r--r--@  1 patrickdorival  staff  16140 19 Apr 22:17 Cargo.lock
-rw-r--r--@  1 patrickdorival  staff    916 19 Apr 21:14 Cargo.toml
drwxr-xr-x@  8 patrickdorival  staff    256 19 Apr 21:14 crates
drwxr-xr-x@  5 patrickdorival  staff    160 19 Apr 21:40 protocols
drwxr-xr-x@ 14 patrickdorival  staff    448 19 Apr 21:38 skills
drwxr-xr-x@  6 patrickdorival  staff    192 19 Apr 22:23 target

```

**Tool: glob**

**Input:**
```json
{
  "pattern": "**/*.go"
}
```

**Output:**
```
No files found
```

**Tool: bash**

**Input:**
```json
{
  "command": "which locus",
  "description": "Find where locus binary is installed"
}
```

**Output:**
```
/usr/local/bin/locus

```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 3.1s)

I see this is a Rust project. Let me explore the structure:

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus</path>
<type>directory</type>
<entries>
.git/
.gitignore
agents/
algorithm/
Cargo.lock
Cargo.toml
crates/
protocols/
skills/
target/

(10 entries)
</entries>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/Cargo.toml"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/Cargo.toml</path>
<type>file</type>
<content>
1: [workspace]
2: resolver = "2"
3: members = [
4:     "crates/locus-cli",
5:     "crates/locus-core",
6:     "crates/locus-adapter-opencode",
7:     "crates/locus-adapter-claude",
8:     "crates/locus-index",
9:     "crates/locus-tools",
10: ]
11: 
12: [workspace.package]
13: version = "0.1.0"
14: edition = "2021"
15: license = "Apache-2.0"
16: repository = "https://github.com/devergehq/locus"
17: authors = ["Patrick D'Orival <patrick@deverge.com>"]
18: 
19: [workspace.dependencies]
20: # Shared across crates
21: serde = { version = "1", features = ["derive"] }
22: serde_json = "1"
23: serde_yaml = "0.9"
24: thiserror = "2"
25: tracing = "0.1"
26: tokio = { version = "1", features = ["full"] }
27: async-trait = "0.1"
28: 
29: # Internal crates
30: locus-core = { path = "crates/locus-core" }
31: locus-tools = { path = "crates/locus-tools" }
32: locus-index = { path = "crates/locus-index" }
33: locus-adapter-opencode = { path = "crates/locus-adapter-opencode" }
34: locus-adapter-claude = { path = "crates/locus-adapter-claude" }

(End of file - total 34 lines)
</content>
```

**Tool: glob**

**Input:**
```json
{
  "pattern": "**/*.rs"
}
```

**Output:**
```
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-opencode/src/lib.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-opencode/src/config_gen.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/platform.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/main.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/mod.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/sync.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/init.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-opencode/src/events.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-opencode/src/capabilities.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/output.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/skill.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/doctor.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/lib.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/error.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/memory.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/skill.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/config.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/adapter.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/capabilities.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/events.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/platform.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-tools/src/lib.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-index/src/lib.rs
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-claude/src/lib.rs
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 3.5s)

Let me examine the CLI structure to understand how commands are organized:

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/main.rs"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/main.rs</path>
<type>file</type>
<content>
1: //! Locus CLI — the entry point for the Locus agentic workflow framework.
2: 
3: mod commands;
4: mod output;
5: 
6: use clap::{Parser, Subcommand};
7: 
8: #[derive(Parser)]
9: #[command(
10:     name = "locus",
11:     about = "Agentic AI workflow execution framework",
12:     version,
13:     propagate_version = true
14: )]
15: struct Cli {
16:     #[command(subcommand)]
17:     command: Commands,
18: }
19: 
20: #[derive(Subcommand)]
21: enum Commands {
22:     /// Initialise a new Locus installation.
23:     ///
24:     /// Scaffolds ~/.locus/ with default configuration, detects your
25:     /// environment (shell, editor, git config), and sets up the
26:     /// data directory for persistent memory.
27:     Init {
28:         /// Skip environment detection and use bare defaults.
29:         #[arg(long)]
30:         bare: bool,
31:     },
32: 
33:     /// Validate the Locus installation.
34:     ///
35:     /// Checks config, platform adapters, directory structure,
36:     /// and reports any issues.
37:     Doctor,
38: 
39:     /// Manage platform adapters.
40:     Platform {
41:         #[command(subcommand)]
42:         command: PlatformCommands,
43:     },
44: 
45:     /// Browse and inspect available skills.
46:     Skill {
47:         #[command(subcommand)]
48:         command: SkillCommands,
49:     },
50: 
51:     /// Synchronise user data between machines via git.
52:     ///
53:     /// Commits local changes and pushes/pulls from the remote.
54:     /// Use --init to set up the data directory as a git repo.
55:     Sync {
56:         /// Initialise data dir as git repo with this remote URL.
57:         #[arg(long = "init")]
58:         init_remote: Option<String>,
59:     },
60: }
61: 
62: #[derive(Subcommand)]
63: enum PlatformCommands {
64:     /// List all supported platforms and their status.
65:     List,
66: 
67:     /// Add a platform adapter and generate its configuration.
68:     Add {
69:         /// Platform to add (e.g., "opencode", "claude-code").
70:         platform: String,
71:     },
72: 
73:     /// Remove a platform adapter.
74:     Remove {
75:         /// Platform to remove.
76:         platform: String,
77:     },
78: }
79: 
80: #[derive(Subcommand)]
81: enum SkillCommands {
82:     /// List all available skills.
83:     List,
84: 
85:     /// Show detailed info about a specific skill.
86:     Info {
87:         /// Skill identifier (e.g., "research", "council").
88:         skill: String,
89:     },
90: }
91: 
92: fn main() {
93:     let cli = Cli::parse();
94: 
95:     let result = match cli.command {
96:         Commands::Init { bare } => commands::init::run(bare),
97:         Commands::Doctor => commands::doctor::run(),
98:         Commands::Platform { command } => match command {
99:             PlatformCommands::List => commands::platform::list(),
100:             PlatformCommands::Add { platform } => commands::platform::add(&platform),
101:             PlatformCommands::Remove { platform } => commands::platform::remove(&platform),
102:         },
103:         Commands::Skill { command } => match command {
104:             SkillCommands::List => commands::skill::list(),
105:             SkillCommands::Info { skill } => commands::skill::info(&skill),
106:         },
107:         Commands::Sync { init_remote } => commands::sync::run(init_remote),
108:     };
109: 
110:     if let Err(e) = result {
111:         output::error(&e.to_string());
112:         std::process::exit(1);
113:     }
114: }

(End of file - total 114 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/mod.rs"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/mod.rs</path>
<type>file</type>
<content>
1: pub mod doctor;
2: pub mod init;
3: pub mod platform;
4: pub mod skill;
5: pub mod sync;

(End of file - total 5 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/Cargo.toml"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/Cargo.toml</path>
<type>file</type>
<content>
1: [package]
2: name = "locus-cli"
3: description = "CLI binary for the Locus agentic workflow framework"
4: version.workspace = true
5: edition.workspace = true
6: license.workspace = true
7: repository.workspace = true
8: authors.workspace = true
9: 
10: [[bin]]
11: name = "locus"
12: path = "src/main.rs"
13: 
14: [dependencies]
15: locus-core = { workspace = true }
16: locus-tools = { workspace = true }
17: locus-index = { workspace = true }
18: locus-adapter-opencode = { workspace = true }
19: locus-adapter-claude = { workspace = true }
20: serde = { workspace = true }
21: serde_json = { workspace = true }
22: serde_yaml = { workspace = true }
23: thiserror = { workspace = true }
24: tracing = { workspace = true }
25: tokio = { workspace = true }
26: clap = { version = "4", features = ["derive"] }
27: colored = "3.1.1"
28: dirs = "6.0.0"

(End of file - total 28 lines)
</content>
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 5.5s)

Let me look at an example command implementation to understand the pattern:

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/doctor.rs"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/commands/doctor.rs</path>
<type>file</type>
<content>
1: //! `locus doctor` — validate the Locus installation.
2: 
3: use std::path::PathBuf;
4: 
5: use locus_core::config::LocusConfig;
6: use locus_core::platform::Platform;
7: use locus_core::LocusError;
8: 
9: use crate::output;
10: 
11: /// Run the doctor command.
12: pub fn run() -> Result<(), LocusError> {
13:     output::print_header();
14:     output::section("System Check");
15: 
16:     let home = resolve_home()?;
17:     let mut issues: Vec<String> = Vec::new();
18:     let mut warnings: Vec<String> = Vec::new();
19: 
20:     // 1. Check Locus home exists.
21:     check_directory(&home, "Locus home", &mut issues);
22: 
23:     // 2. Check config file.
24:     let config_path = home.join("locus.yaml");
25:     let config = check_config(&config_path, &mut issues);
26: 
27:     // 3. Check data directories.
28:     output::section("Data Directories");
29:     let data_dir = config
30:         .as_ref()
31:         .and_then(|c| c.resolve_data_dir().ok())
32:         .unwrap_or_else(|| home.join("data"));
33: 
34:     for subdir in &["memory/work", "memory/learning", "memory/research", "memory/state", "projects", "context-packs"] {
35:         let path = data_dir.join(subdir);
36:         if path.exists() {
37:             output::success(&format!("data/{}", subdir));
38:         } else {
39:             output::warn(&format!("data/{} — missing", subdir));
40:             warnings.push(format!("Missing data directory: data/{}", subdir));
41:         }
42:     }
43: 
44:     // 4. Check platforms.
45:     output::section("Platforms");
46:     if let Some(ref config) = config {
47:         if config.platforms.is_empty() {
48:             output::warn("No platforms configured");
49:             warnings.push("No platform adapters configured. Run `locus platform add <platform>`.".into());
50:         } else {
51:             for platform in &config.platforms {
52:                 check_platform(platform, &mut issues, &mut warnings);
53:             }
54:         }
55:     }
56: 
57:     // 5. Check platform binaries.
58:     output::section("External Tools");
59:     check_binary("git", "Git (required for sync)", &mut issues);
60: 
61:     // Summary.
62:     output::section("Summary");
63:     if issues.is_empty() && warnings.is_empty() {
64:         output::success("All checks passed");
65:     } else {
66:         if !warnings.is_empty() {
67:             for w in &warnings {
68:                 output::warn(w);
69:             }
70:         }
71:         if !issues.is_empty() {
72:             for i in &issues {
73:                 output::error(i);
74:             }
75:         }
76:         println!();
77:         output::info(&format!(
78:             "{} issue(s), {} warning(s)",
79:             issues.len(),
80:             warnings.len()
81:         ));
82:     }
83: 
84:     println!();
85:     Ok(())
86: }
87: 
88: fn resolve_home() -> Result<PathBuf, LocusError> {
89:     if let Ok(env_home) = std::env::var("LOCUS_HOME") {
90:         return Ok(PathBuf::from(env_home));
91:     }
92:     dirs::home_dir()
93:         .map(|h| h.join(".locus"))
94:         .ok_or_else(|| LocusError::Config {
95:             message: "Could not determine home directory".into(),
96:             path: None,
97:         })
98: }
99: 
100: fn check_directory(path: &PathBuf, label: &str, issues: &mut Vec<String>) {
101:     if path.exists() {
102:         output::success(&format!("{} ({})", label, path.display()));
103:     } else {
104:         output::error(&format!("{} — not found ({})", label, path.display()));
105:         issues.push(format!("{} not found at {}", label, path.display()));
106:     }
107: }
108: 
109: fn check_config(path: &PathBuf, issues: &mut Vec<String>) -> Option<LocusConfig> {
110:     if !path.exists() {
111:         output::error(&format!("Config — not found ({})", path.display()));
112:         issues.push("locus.yaml not found. Run `locus init`.".into());
113:         return None;
114:     }
115: 
116:     match LocusConfig::from_file(path) {
117:         Ok(config) => {
118:             output::success(&format!("Config — valid ({})", path.display()));
119:             Some(config)
120:         }
121:         Err(e) => {
122:             output::error(&format!("Config — invalid: {}", e));
123:             issues.push(format!("Invalid config: {}", e));
124:             None
125:         }
126:     }
127: }
128: 
129: fn check_platform(platform: &Platform, issues: &mut Vec<String>, warnings: &mut Vec<String>) {
130:     let home = match dirs::home_dir() {
131:         Some(h) => h,
132:         None => return,
133:     };
134: 
135:     let config_dir = home.join(platform.config_dir_name());
136:     let cli_available = std::process::Command::new("which")
137:         .arg(platform.cli_command())
138:         .output()
139:         .map(|o| o.status.success())
140:         .unwrap_or(false);
141: 
142:     if config_dir.exists() && cli_available {
143:         output::success(&format!(
144:             "{} — config dir and CLI found",
145:             platform.display_name()
146:         ));
147:     } else if config_dir.exists() {
148:         output::warn(&format!(
149:             "{} — config dir found but `{}` CLI not on PATH",
150:             platform.display_name(),
151:             platform.cli_command()
152:         ));
153:         warnings.push(format!(
154:             "{} CLI not found on PATH",
155:             platform.display_name()
156:         ));
157:     } else {
158:         output::error(&format!(
159:             "{} — not installed (no {} directory)",
160:             platform.display_name(),
161:             platform.config_dir_name()
162:         ));
163:         issues.push(format!(
164:             "{} is configured but not installed",
165:             platform.display_name()
166:         ));
167:     }
168: }
169: 
170: fn check_binary(name: &str, label: &str, issues: &mut Vec<String>) {
171:     let available = std::process::Command::new("which")
172:         .arg(name)
173:         .output()
174:         .map(|o| o.status.success())
175:         .unwrap_or(false);
176: 
177:     if available {
178:         output::success(label);
179:     } else {
180:         output::error(&format!("{} — not found", label));
181:         issues.push(format!("{} not found on PATH", name));
182:     }
183: }

(End of file - total 183 lines)
</content>
```

**Tool: read**

**Input:**
```json
{
  "filePath": "/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/output.rs"
}
```

**Output:**
```
<path>/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/output.rs</path>
<type>file</type>
<content>
1: //! Terminal output formatting helpers.
2: 
3: use colored::Colorize;
4: 
5: /// Print the Locus header/banner.
6: pub fn print_header() {
7:     println!(
8:         "{} {}",
9:         "locus".bold().cyan(),
10:         format!("v{}", env!("CARGO_PKG_VERSION")).dimmed()
11:     );
12: }
13: 
14: /// Print a success message.
15: pub fn success(message: &str) {
16:     println!("  {} {}", "✓".green().bold(), message);
17: }
18: 
19: /// Print an info message.
20: pub fn info(message: &str) {
21:     println!("  {} {}", "·".dimmed(), message);
22: }
23: 
24: /// Print a warning message.
25: pub fn warn(message: &str) {
26:     println!("  {} {}", "!".yellow().bold(), message);
27: }
28: 
29: /// Print an error message.
30: pub fn error(message: &str) {
31:     eprintln!("  {} {}", "✗".red().bold(), message);
32: }
33: 
34: /// Print a section header.
35: pub fn section(title: &str) {
36:     println!("\n  {}", title.bold());
37: }
38: 
39: /// Print a key-value pair with alignment.
40: #[allow(dead_code)]
41: pub fn field(key: &str, value: &str) {
42:     println!("  {} {}", format!("{:<16}", key).dimmed(), value);
43: }
44: 
45: /// Print a list item.
46: pub fn list_item(label: &str, description: &str) {
47:     println!("    {} {}", label.bold(), description.dimmed());
48: }

(End of file - total 48 lines)
</content>
```

**Tool: bash**

**Input:**
```json
{
  "command": "gh api repos/devergehq/locus/releases/latest 2>&1 || echo \"Repository may not exist yet or no releases\"",
  "description": "Check if GitHub repo has releases"
}
```

**Output:**
```
{"message":"Not Found","documentation_url":"https://docs.github.com/rest/releases/releases#get-the-latest-release","status":"404"}gh: Not Found (HTTP 404)
Repository may not exist yet or no releases

```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 4.7s)

Let me also check if there's any existing version information in the codebase:

**Tool: bash**

**Input:**
```json
{
  "command": "locus --version 2>/dev/null || echo \"locus not installed or not working\"",
  "description": "Check current locus version"
}
```

**Output:**
```
locus 0.1.0

```

**Tool: grep**

**Input:**
```json
{
  "pattern": "VERSION|version",
  "include": "*.rs"
}
```

**Output:**
```
Found 5 matches
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/main.rs:
  Line 12:     version,

  Line 13:     propagate_version = true


/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/src/output.rs:
  Line 10:         format!("v{}", env!("CARGO_PKG_VERSION")).dimmed()


/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/lib.rs:
  Line 18: //! - **Dependency inversion**: this crate defines interfaces, never implementations.


/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/src/memory.rs:
  Line 5: //! and is version-controlled separately from the core system.

```

**Tool: bash**

**Input:**
```json
{
  "command": "ls -lh /usr/local/bin/locus",
  "description": "Check locus binary info"
}
```

**Output:**
```
-rwxr-xr-x@ 1 patrickdorival  admin   1.6M 19 Apr 23:43 /usr/local/bin/locus

```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 3.7s)

Now let me check how the binary is currently installed and look at build/release configurations:

**Tool: bash**

**Input:**
```json
{
  "command": "file /usr/local/bin/locus",
  "description": "Check binary type"
}
```

**Output:**
```
/usr/local/bin/locus: Mach-O 64-bit executable arm64

```

**Tool: glob**

**Input:**
```json
{
  "pattern": "**/*.toml"
}
```

**Output:**
```
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-opencode/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-cli/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-core/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-tools/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-index/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/crates/locus-adapter-claude/Cargo.toml
/Users/patrickdorival/sites/clients/deverge/locus/Cargo.toml
```

**Tool: bash**

**Input:**
```json
{
  "command": "uname -sm",
  "description": "Check system architecture"
}
```

**Output:**
```
Darwin arm64

```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 18.0s)

Perfect! Now I have enough context. Let me think through the design approach for the `locus upgrade` command.

## Analysis & Design Approach for `locus upgrade`

Based on my exploration, here's what I've learned:

### Current State
- **Language**: Rust-based CLI using Clap for command parsing
- **Version**: Currently 0.1.0 (from workspace Cargo.toml)
- **Binary location**: `/usr/local/bin/locus`
- **Platform**: macOS ARM64 (darwin arm64)
- **Repository**: `https://github.com/devergehq/locus` (no releases yet)
- **Structure**: Commands are in `crates/locus-cli/src/commands/` with a module per command

### Key Design Considerations

I'd like to walk through several approaches and get your input:

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "GitHub Release Strategy",
      "question": "How should the upgrade command determine what release to use?",
      "options": [
        {
          "label": "Latest GitHub Release",
          "description": "Use GitHub Releases API to find the latest release version and download pre-built binaries"
        },
        {
          "label": "Tagged Releases Only",
          "description": "Only use releases with specific version tags (e.g., v0.1.0, v0.2.0) and ignore pre-releases"
        },
        {
          "label": "Both with flag",
          "description": "Default to stable releases, but allow --pre-release flag to get pre-release versions"
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "How should the upgrade command determine what release to use?"="Latest GitHub Release". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 17.4s)

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "Multi-Platform Support",
      "question": "Should the upgrade command support multiple platforms from day one?",
      "options": [
        {
          "label": "Multi-platform from start",
          "description": "Detect OS/arch and download the correct binary (macOS arm64/x86, Linux arm64/x86, Windows)"
        },
        {
          "label": "Current platform only",
          "description": "Start with macOS ARM64 support only, add others incrementally"
        },
        {
          "label": "Auto-detect with fallback",
          "description": "Try to detect platform and download appropriate binary, but provide clear error if unsupported"
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "Should the upgrade command support multiple platforms from day one?"="Multi-platform from start". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 17.8s)

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "Update Mechanism",
      "question": "What should the upgrade process look like?",
      "options": [
        {
          "label": "In-place replacement",
          "description": "Download new binary to temp location, verify it, then replace current binary atomically"
        },
        {
          "label": "With backup",
          "description": "Backup current binary before replacement, allow rollback if new version has issues"
        },
        {
          "label": "Self-extracting installer",
          "description": "Download installer that handles the replacement process"
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "What should the upgrade process look like?"="In-place replacement". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 17.9s)

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "Verification & Safety",
      "question": "How should we verify downloaded binaries?",
      "options": [
        {
          "label": "Checksum verification (Recommended)",
          "description": "Verify SHA256 checksum against published checksums in the release"
        },
        {
          "label": "Signature verification",
          "description": "Use GPG signatures to verify authenticity (requires key management)"
        },
        {
          "label": "Basic checks only",
          "description": "Just verify download completed and file is executable"
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "How should we verify downloaded binaries?"="Checksum verification (Recommended)". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 42.5s)

**Tool: question**

**Input:**
```json
{
  "questions": [
    {
      "header": "User Experience",
      "question": "What flags and behaviors should the upgrade command support?",
      "options": [
        {
          "label": "Rich feature set (Recommended)",
          "description": "--check (check only), --force (skip version check), --dry-run, progress bars, confirmations"
        },
        {
          "label": "Minimal set",
          "description": "Just the upgrade command with optional --force flag"
        },
        {
          "label": "Interactive mode",
          "description": "Show what will be upgraded and ask for confirmation before proceeding"
        }
      ]
    }
  ]
}
```

**Output:**
```
User has answered your questions: "What flags and behaviors should the upgrade command support?"="Rich feature set (Recommended)". You can now continue with the user's answers in mind.
```

---

## Assistant (Plan · Claude Sonnet 4.5 (latest) · 30.7s)

Excellent! Based on your preferences, here's my comprehensive plan:

## Proposed Implementation Plan

### 1. **Command Structure**

Add `Upgrade` variant to the `Commands` enum in `main.rs`:

```rust
Commands::Upgrade {
    /// Only check for updates without installing
    #[arg(long)]
    check: bool,
    
    /// Force upgrade even if already up to date
    #[arg(long)]
    force: bool,
    
    /// Show what would be done without actually upgrading
    #[arg(long)]
    dry_run: bool,
}
```

### 2. **New Module**: `crates/locus-cli/src/commands/upgrade.rs`

This module will handle:
- **Version comparison**: Compare current version (from `CARGO_PKG_VERSION`) vs GitHub latest
- **Platform detection**: Detect OS and architecture (darwin/linux/windows × arm64/x86_64)
- **Download management**: Fetch the appropriate binary from GitHub releases
- **Checksum verification**: Validate SHA256 against published checksums
- **Atomic replacement**: Replace binary safely with proper permissions

### 3. **Dependencies to Add**

```toml
reqwest = { version = "0.12", features = ["blocking", "json"] }
sha2 = "0.10"
tempfile = "3"
```

### 4. **Implementation Flow**

```
1. Parse current version from CARGO_PKG_VERSION
2. Fetch latest release from GitHub API
   - Endpoint: https://api.github.com/repos/devergehq/locus/releases/latest
3. Compare versions (semver comparison)
4. If --check flag: display comparison and exit
5. Detect platform (os + arch)
6. Find matching asset in release
   - Expected naming: locus-{version}-{os}-{arch}[.exe]
   - e.g., locus-v0.2.0-darwin-arm64
7. Download checksum file (e.g., checksums.txt)
8. Download binary to temp location
9. Verify checksum matches
10. If --dry-run: show what would happen and exit
11. Detect current binary location (from std::env::current_exe())
12. Replace binary atomically:
    - Write new binary to temp file in same directory
    - Set executable permissions
    - Rename (atomic on Unix) old → new
13. Verify new binary works (run --version)
14. Report success
```

### 5. **Asset Naming Convention**

For GitHub releases, you'll need to publish binaries with this structure:

```
locus-v0.2.0-darwin-arm64
locus-v0.2.0-darwin-x86_64
locus-v0.2.0-linux-arm64
locus-v0.2.0-linux-x86_64
locus-v0.2.0-windows-x86_64.exe
checksums.txt
```

The `checksums.txt` format:
```
<sha256>  locus-v0.2.0-darwin-arm64
<sha256>  locus-v0.2.0-darwin-x86_64
...
```

### 6. **Error Handling**

Handle these error cases gracefully:
- No internet connection
- GitHub API rate limiting
- No releases available
- No binary for current platform
- Checksum mismatch
- Permission denied (need sudo)
- Binary already in use

### 7. **Output Examples**

**Check mode** (`locus upgrade --check`):
```
locus v0.1.0

  Checking for updates...
  ✓ Current version: 0.1.0
  ✓ Latest version: 0.2.0
  
  ! Update available: 0.1.0 → 0.2.0
```

**Upgrade** (`locus upgrade`):
```
locus v0.1.0

  Checking for updates...
  ✓ Current version: 0.1.0
  ✓ Latest version: 0.2.0
  
  Upgrading locus 0.1.0 → 0.2.0
  ✓ Downloading locus-v0.2.0-darwin-arm64 (1.8 MB)
  ✓ Verifying checksum
  ✓ Installing to /usr/local/bin/locus
  ✓ Upgrade complete
  
  Run `locus --version` to verify.
```

### 8. **Build Process Changes**

You'll eventually need a CI/CD workflow (GitHub Actions) to:
1. Build binaries for all platforms on release tags
2. Generate checksums.txt
3. Create GitHub release with all assets

### 9. **Platform Detection Logic**

```rust
fn detect_platform() -> Result<(String, String), LocusError> {
    let os = std::env::consts::OS; // "macos", "linux", "windows"
    let arch = std::env::consts::ARCH; // "aarch64", "x86_64"
    
    let os_name = match os {
        "macos" => "darwin",
        "linux" => "linux",
        "windows" => "windows",
        _ => return Err(LocusError::UnsupportedPlatform(os.to_string())),
    };
    
    let arch_name = match arch {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        _ => return Err(LocusError::UnsupportedArchitecture(arch.to_string())),
    };
    
    Ok((os_name.to_string(), arch_name.to_string()))
}
```

### 10. **Questions for You**

Before I finalize the plan:

1. **Permissions handling**: If the user doesn't have write permission to `/usr/local/bin/locus`, should we:
   - Prompt them to run with sudo?
   - Try to detect and suggest `sudo locus upgrade`?
   - Use a privilege escalation library?

2. **Installation method awareness**: Should we detect HOW locus was installed?
   - If via Homebrew → suggest `brew upgrade locus`
   - If via cargo → suggest `cargo install --force locus`
   - Only upgrade self-installed binaries?

3. **Backup strategy**: Even though you chose "in-place replacement", should we:
   - Keep a `.locus.bak` backup temporarily?
   - Or trust the user can reinstall from GitHub if needed?

4. **Version pinning**: Should users be able to:
   - Upgrade to a specific version? (`locus upgrade --version 0.2.0`)
   - Or only latest?

What are your thoughts on these additional considerations?

---

