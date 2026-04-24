//! Locus configuration types.
//!
//! The [`LocusConfig`] struct represents the canonical `locus.yaml` file —
//! the single source of truth for all Locus settings. Platform-specific
//! config files are generated from this.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::error::LocusError;
use crate::platform::Platform;

/// Top-level Locus configuration, representing `locus.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocusConfig {
    /// Active platform(s). First entry is the primary.
    pub platforms: Vec<Platform>,

    /// Algorithm configuration.
    #[serde(default)]
    pub algorithm: AlgorithmConfig,

    /// Skill configuration.
    #[serde(default)]
    pub skills: SkillConfig,

    /// Notification settings.
    #[serde(default)]
    pub notifications: NotificationConfig,

    /// Inference provider settings.
    #[serde(default)]
    pub inference: InferenceConfig,

    /// Path overrides (optional — defaults to XDG-compliant paths).
    #[serde(default)]
    pub paths: PathConfig,

    /// Per-platform overrides for adapter-specific settings.
    #[serde(default)]
    pub platform_overrides: HashMap<Platform, serde_yaml::Value>,

    /// Routing defaults for `locus delegate run`.
    #[serde(default)]
    pub delegation: DelegationConfig,
}

/// Routing defaults for delegated execution.
///
/// Lets `locus delegate run` resolve `--model` (and optionally `--variant`,
/// `--agent`) from configuration rather than requiring them on every call.
/// Outer key is the backend's snake_case name (e.g. `opencode`); inner key
/// is the task kind's snake_case name (e.g. `research`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DelegationConfig {
    /// Per-backend, per-task-kind defaults.
    #[serde(default)]
    pub defaults: HashMap<String, HashMap<String, DelegationDefaults>>,
}

/// Default invocation settings for a (backend, task_kind) route.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DelegationDefaults {
    /// Provider/model identifier, e.g. `openai/gpt-5.5`.
    pub model: String,
    /// Optional provider-specific reasoning variant.
    #[serde(default)]
    pub variant: Option<String>,
    /// Optional backend agent/profile name.
    #[serde(default)]
    pub agent: Option<String>,
}

impl DelegationConfig {
    /// Look up defaults for the given backend/task-kind pair.
    ///
    /// Both keys are the snake_case stable names exposed by
    /// `DelegationBackend::as_str` and `DelegationTaskKind::as_str`.
    pub fn lookup(&self, backend: &str, task_kind: &str) -> Option<&DelegationDefaults> {
        self.defaults.get(backend).and_then(|m| m.get(task_kind))
    }
}

/// Algorithm behaviour settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AlgorithmConfig {
    /// Default effort level for Algorithm mode.
    #[serde(default = "AlgorithmConfig::default_effort")]
    pub default_effort: EffortLevel,

    /// Whether to automatically checkpoint state between phases.
    #[serde(default = "AlgorithmConfig::default_checkpoint")]
    pub auto_checkpoint: bool,
}

impl Default for AlgorithmConfig {
    fn default() -> Self {
        Self {
            default_effort: Self::default_effort(),
            auto_checkpoint: Self::default_checkpoint(),
        }
    }
}

impl AlgorithmConfig {
    fn default_effort() -> EffortLevel {
        EffortLevel::Standard
    }

    fn default_checkpoint() -> bool {
        true
    }
}

/// Effort levels for the Algorithm's phased decomposition.
///
/// Higher effort means more thorough analysis at each phase,
/// more context gathering, and more verification steps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EffortLevel {
    /// Quick execution — minimal analysis, fast results.
    /// Good for simple, well-understood tasks.
    Minimal,

    /// Standard execution — balanced analysis and speed.
    /// The default for most tasks.
    Standard,

    /// Thorough execution — deeper analysis, more context gathering.
    /// For complex tasks touching multiple systems.
    Extended,

    /// Maximum execution — comprehensive analysis at every phase.
    /// For critical architectural decisions and complex refactors.
    Comprehensive,
}

/// Skill system configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SkillConfig {
    /// Skills to always surface (by slug). These appear in the system prompt.
    #[serde(default)]
    pub pinned: Vec<String>,

    /// Skills to never surface, even if contextually relevant.
    #[serde(default)]
    pub disabled: Vec<String>,
}

impl Default for SkillConfig {
    fn default() -> Self {
        Self {
            pinned: Vec::new(),
            disabled: Vec::new(),
        }
    }
}

/// Notification settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationConfig {
    /// Whether notifications are enabled.
    #[serde(default = "NotificationConfig::default_enabled")]
    pub enabled: bool,

    /// Notification methods to use.
    #[serde(default)]
    pub methods: Vec<NotificationMethod>,
}

impl Default for NotificationConfig {
    fn default() -> Self {
        Self {
            enabled: Self::default_enabled(),
            methods: Vec::new(),
        }
    }
}

impl NotificationConfig {
    fn default_enabled() -> bool {
        false
    }
}

/// Available notification methods.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum NotificationMethod {
    /// Desktop notifications via the OS notification centre.
    Desktop,

    /// Voice notifications via a TTS provider.
    Voice {
        /// TTS provider (e.g., "elevenlabs").
        provider: String,
        /// Voice ID for the TTS provider.
        voice_id: Option<String>,
    },

    /// Webhook notifications (POST to a URL).
    Webhook {
        /// The URL to POST to.
        url: String,
    },
}

/// Inference provider configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InferenceConfig {
    /// Default provider for tool inference calls.
    #[serde(default = "InferenceConfig::default_provider")]
    pub default_provider: String,

    /// Model to use for inference.
    #[serde(default)]
    pub model: Option<String>,

    /// API keys, keyed by provider name.
    /// These can also be set via environment variables (LOCUS_API_KEY_{PROVIDER}).
    #[serde(default)]
    pub api_keys: HashMap<String, String>,
}

impl Default for InferenceConfig {
    fn default() -> Self {
        Self {
            default_provider: Self::default_provider(),
            model: None,
            api_keys: HashMap::new(),
        }
    }
}

impl InferenceConfig {
    fn default_provider() -> String {
        "anthropic".into()
    }
}

/// Path overrides for non-standard installations.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PathConfig {
    /// Override the Locus home directory (default: ~/.locus/).
    pub home: Option<PathBuf>,

    /// Override the user data directory (default: ~/.locus/data/).
    pub data: Option<PathBuf>,
}

impl LocusConfig {
    /// Load config from a YAML file.
    pub fn from_file(path: &Path) -> Result<Self, LocusError> {
        let content = std::fs::read_to_string(path).map_err(|e| LocusError::Config {
            message: format!("Failed to read config file: {}", e),
            path: Some(path.to_path_buf()),
        })?;

        serde_yaml::from_str(&content).map_err(|e| LocusError::Config {
            message: format!("Failed to parse config: {}", e),
            path: Some(path.to_path_buf()),
        })
    }

    /// Serialize config to YAML string.
    pub fn to_yaml(&self) -> Result<String, LocusError> {
        serde_yaml::to_string(self).map_err(|e| LocusError::Config {
            message: format!("Failed to serialize config: {}", e),
            path: None,
        })
    }

    /// Returns the primary platform (first in the list).
    pub fn primary_platform(&self) -> Option<Platform> {
        self.platforms.first().copied()
    }

    /// Returns the resolved Locus home directory.
    ///
    /// Resolution order:
    /// 1. `LOCUS_HOME` environment variable
    /// 2. `paths.home` in config
    /// 3. `~/.locus/`
    pub fn resolve_home(&self) -> Result<PathBuf, LocusError> {
        if let Ok(env_home) = std::env::var("LOCUS_HOME") {
            return Ok(PathBuf::from(env_home));
        }

        if let Some(ref home) = self.paths.home {
            return Ok(home.clone());
        }

        dirs::home_dir()
            .map(|h| h.join(".locus"))
            .ok_or_else(|| LocusError::Config {
                message: "Could not determine home directory".into(),
                path: None,
            })
    }

    /// Returns the resolved user data directory.
    ///
    /// Resolution order:
    /// 1. `LOCUS_DATA_HOME` environment variable
    /// 2. `paths.data` in config
    /// 3. `{locus_home}/data/`
    pub fn resolve_data_dir(&self) -> Result<PathBuf, LocusError> {
        if let Ok(env_data) = std::env::var("LOCUS_DATA_HOME") {
            return Ok(PathBuf::from(env_data));
        }

        if let Some(ref data) = self.paths.data {
            return Ok(data.clone());
        }

        self.resolve_home().map(|h| h.join("data"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minimal_config_parses() {
        let yaml = r#"
platforms:
  - open-code
"#;
        let config: LocusConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(config.platforms, vec![Platform::OpenCode]);
        assert_eq!(config.algorithm.default_effort, EffortLevel::Standard);
        assert!(config.algorithm.auto_checkpoint);
    }

    #[test]
    fn full_config_parses() {
        let yaml = r#"
platforms:
  - open-code
  - claude-code

algorithm:
  default_effort: extended
  auto_checkpoint: false

skills:
  pinned:
    - research
    - thinking
  disabled:
    - security

notifications:
  enabled: true
  methods:
    - type: desktop
    - type: voice
      provider: elevenlabs
      voice_id: abc123

inference:
  default_provider: anthropic
  model: claude-sonnet-4-20250514

paths:
  data: /custom/data/path

delegation:
  defaults:
    opencode:
      research:
        model: openai/gpt-5.5
        variant: high
      code_exploration:
        model: openai/gpt-5.4-mini
"#;
        let config: LocusConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(config.platforms.len(), 2);
        assert_eq!(config.algorithm.default_effort, EffortLevel::Extended);
        assert!(!config.algorithm.auto_checkpoint);
        assert_eq!(config.skills.pinned.len(), 2);
        assert!(config.notifications.enabled);
        assert_eq!(
            config.inference.model,
            Some("claude-sonnet-4-20250514".into())
        );
        let research = config
            .delegation
            .lookup("opencode", "research")
            .expect("research default present");
        assert_eq!(research.model, "openai/gpt-5.5");
        assert_eq!(research.variant.as_deref(), Some("high"));
        assert!(research.agent.is_none());
        assert_eq!(
            config
                .delegation
                .lookup("opencode", "code_exploration")
                .map(|d| d.model.as_str()),
            Some("openai/gpt-5.4-mini")
        );
    }

    #[test]
    fn delegation_section_defaults_when_absent() {
        let yaml = "platforms: [open-code]";
        let config: LocusConfig = serde_yaml::from_str(yaml).unwrap();
        assert!(config.delegation.defaults.is_empty());
        assert!(config.delegation.lookup("opencode", "research").is_none());
    }

    #[test]
    fn primary_platform() {
        let yaml = "platforms: [open-code, claude-code]";
        let config: LocusConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(config.primary_platform(), Some(Platform::OpenCode));
    }

    #[test]
    fn effort_level_serde() {
        let json = serde_json::to_string(&EffortLevel::Comprehensive).unwrap();
        assert_eq!(json, "\"comprehensive\"");
    }
}
