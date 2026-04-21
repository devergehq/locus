//! Trait-based agent composition.
//!
//! Reads `agents/traits.yaml` and composes agent prompts from selected trait
//! IDs. Each trait contributes a `prompt_fragment`; the composition concatenates
//! fragments into a coherent prompt with an optional role and task.
//!
//! Design rationale (evidence-backed):
//! - Named characters with backstories cause persona drift and stereotype
//!   activation; trait stances produce stable, distinct cognitive profiles.
//!   See `agents/traits.yaml` header for citations.
//! - Composition is deterministic: same trait IDs in same order produce the
//!   same prompt byte-for-byte. This is required for verification.
//!
//! The `Traits` root is serde-deserialisable from YAML. Unknown axes are
//! ignored rather than erroring — forward-compatible with future axes.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::LocusError;

/// A single trait definition from `traits.yaml`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trait {
    /// Human-readable name.
    pub name: String,

    /// Short description of the trait.
    pub description: String,

    /// Prompt text contributed by this trait when composed.
    pub prompt_fragment: String,

    /// Optional routing keywords.
    #[serde(default)]
    pub keywords: Vec<String>,
}

/// The parsed `agents/traits.yaml` document.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Traits {
    /// Version string from the YAML header.
    #[serde(default)]
    pub version: String,

    /// Expertise axis — domain knowledge.
    #[serde(default)]
    pub expertise: BTreeMap<String, Trait>,

    /// Stance axis — how the agent reasons.
    #[serde(default)]
    pub stance: BTreeMap<String, Trait>,

    /// Approach axis — how the agent works through a task.
    #[serde(default)]
    pub approach: BTreeMap<String, Trait>,

    /// Example compositions — reference only, not consumed by compose().
    #[serde(default)]
    pub examples: BTreeMap<String, TraitExample>,
}

/// A reference example composition from the YAML `examples:` section.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraitExample {
    pub description: String,
    pub traits: Vec<String>,
}

/// Result of composing an agent from a set of trait IDs.
#[derive(Debug, Clone, Serialize)]
pub struct ComposedAgent {
    /// The role statement, if one was supplied.
    pub role: Option<String>,

    /// The task statement, if one was supplied.
    pub task: Option<String>,

    /// The trait IDs that were used.
    pub traits: Vec<String>,

    /// The trait names (human-readable), parallel to `traits`.
    pub trait_names: Vec<String>,

    /// Keywords aggregated across all selected traits.
    pub keywords: Vec<String>,

    /// The full composed prompt.
    pub prompt: String,
}

impl Traits {
    /// Load traits from a YAML file.
    pub fn from_file(path: &Path) -> Result<Self, LocusError> {
        let content = std::fs::read_to_string(path).map_err(|e| LocusError::Filesystem {
            message: format!("Failed to read traits file: {}", e),
            path: path.to_path_buf(),
        })?;

        Self::from_yaml(&content)
    }

    /// Parse traits from YAML text.
    pub fn from_yaml(yaml: &str) -> Result<Self, LocusError> {
        serde_yaml::from_str(yaml).map_err(|e| LocusError::Config {
            message: format!("Failed to parse traits.yaml: {}", e),
            path: None,
        })
    }

    /// Look up a trait by ID across all three axes. Returns the trait and
    /// which axis it came from.
    pub fn lookup(&self, id: &str) -> Option<(&str, &Trait)> {
        if let Some(t) = self.expertise.get(id) {
            return Some(("expertise", t));
        }
        if let Some(t) = self.stance.get(id) {
            return Some(("stance", t));
        }
        if let Some(t) = self.approach.get(id) {
            return Some(("approach", t));
        }
        None
    }

    /// Compose an agent prompt from a list of trait IDs, an optional role,
    /// and an optional task.
    ///
    /// Trait IDs are looked up in-order; missing IDs produce a Skill error
    /// naming the unknown trait(s). The composed prompt follows this shape:
    ///
    /// ```text
    /// <role-statement>
    ///
    /// <trait 1 prompt_fragment>
    ///
    /// <trait 2 prompt_fragment>
    ///
    /// ...
    ///
    /// <task-statement>
    /// ```
    ///
    /// Sections are omitted if the corresponding input is `None`.
    pub fn compose(
        &self,
        trait_ids: &[&str],
        role: Option<&str>,
        task: Option<&str>,
    ) -> Result<ComposedAgent, LocusError> {
        let mut traits_used = Vec::with_capacity(trait_ids.len());
        let mut trait_names = Vec::with_capacity(trait_ids.len());
        let mut fragments = Vec::with_capacity(trait_ids.len());
        let mut keywords: Vec<String> = Vec::new();

        for id in trait_ids {
            match self.lookup(id) {
                Some((_, t)) => {
                    traits_used.push((*id).to_string());
                    trait_names.push(t.name.clone());
                    fragments.push(t.prompt_fragment.trim().to_string());
                    for kw in &t.keywords {
                        if !keywords.contains(kw) {
                            keywords.push(kw.clone());
                        }
                    }
                }
                None => {
                    return Err(LocusError::Skill {
                        skill: "agent-compose".into(),
                        message: format!("Unknown trait: '{}'", id),
                    });
                }
            }
        }

        let mut sections: Vec<String> = Vec::new();
        if let Some(r) = role {
            sections.push(format!("You are {}.", r.trim()));
        }
        for frag in &fragments {
            sections.push(frag.clone());
        }
        if let Some(t) = task {
            sections.push(format!("Your task: {}", t.trim()));
        }
        let prompt = sections.join("\n\n");

        Ok(ComposedAgent {
            role: role.map(|s| s.trim().to_string()),
            task: task.map(|s| s.trim().to_string()),
            traits: traits_used,
            trait_names,
            keywords,
            prompt,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_traits() -> Traits {
        let yaml = r#"
version: "1.0"
expertise:
  security:
    name: "Security"
    description: "Threat modelling."
    prompt_fragment: |
      You reason adversarially about systems.
    keywords: [security, threat]
stance:
  skeptical:
    name: "Skeptical"
    description: "Demands evidence."
    prompt_fragment: |
      You demand evidence and question assumptions.
    keywords: [skeptical, critical]
approach:
  thorough:
    name: "Thorough"
    description: "Exhaustive analysis."
    prompt_fragment: |
      Be exhaustive. Cover all angles.
    keywords: [thorough]
"#;
        Traits::from_yaml(yaml).expect("parse sample traits")
    }

    #[test]
    fn parse_traits_yaml() {
        let t = sample_traits();
        assert_eq!(t.expertise.len(), 1);
        assert_eq!(t.stance.len(), 1);
        assert_eq!(t.approach.len(), 1);
    }

    #[test]
    fn lookup_finds_trait_across_axes() {
        let t = sample_traits();
        assert!(matches!(t.lookup("security"), Some(("expertise", _))));
        assert!(matches!(t.lookup("skeptical"), Some(("stance", _))));
        assert!(matches!(t.lookup("thorough"), Some(("approach", _))));
        assert!(t.lookup("nonexistent").is_none());
    }

    #[test]
    fn compose_prompt_concatenates_fragments() {
        let t = sample_traits();
        let composed = t
            .compose(
                &["security", "skeptical", "thorough"],
                Some("Auth reviewer"),
                Some("Review the login flow for injection risks"),
            )
            .unwrap();

        assert_eq!(composed.traits, vec!["security", "skeptical", "thorough"]);
        assert_eq!(
            composed.trait_names,
            vec!["Security", "Skeptical", "Thorough"]
        );
        assert!(composed.prompt.contains("You are Auth reviewer."));
        assert!(composed
            .prompt
            .contains("You reason adversarially about systems."));
        assert!(composed.prompt.contains("You demand evidence"));
        assert!(composed.prompt.contains("Be exhaustive"));
        assert!(composed
            .prompt
            .contains("Your task: Review the login flow"));
    }

    #[test]
    fn compose_without_role_or_task() {
        let t = sample_traits();
        let composed = t.compose(&["skeptical"], None, None).unwrap();
        assert!(!composed.prompt.contains("You are"));
        assert!(!composed.prompt.contains("Your task:"));
        assert!(composed.prompt.contains("You demand evidence"));
    }

    #[test]
    fn compose_unknown_trait_errors() {
        let t = sample_traits();
        let err = t.compose(&["imaginary"], None, None).unwrap_err();
        let msg = format!("{}", err);
        assert!(msg.contains("imaginary"));
    }

    #[test]
    fn compose_is_deterministic() {
        let t = sample_traits();
        let a = t
            .compose(&["security", "skeptical"], Some("X"), Some("Y"))
            .unwrap();
        let b = t
            .compose(&["security", "skeptical"], Some("X"), Some("Y"))
            .unwrap();
        assert_eq!(a.prompt, b.prompt);
    }

    #[test]
    fn compose_aggregates_keywords_deduplicated() {
        let t = sample_traits();
        let c = t
            .compose(&["security", "skeptical"], None, None)
            .unwrap();
        assert!(c.keywords.contains(&"security".to_string()));
        assert!(c.keywords.contains(&"skeptical".to_string()));
    }
}
