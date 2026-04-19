//! Error types for the Locus core.

use std::path::PathBuf;

use crate::platform::Platform;

/// Top-level error type for Locus operations.
#[derive(Debug, thiserror::Error)]
pub enum LocusError {
    /// Configuration error — bad YAML, missing fields, invalid values.
    #[error("Configuration error: {message}")]
    Config {
        message: String,
        path: Option<PathBuf>,
    },

    /// Platform adapter error — something went wrong in adapter translation.
    #[error("{platform} adapter error: {message}")]
    Adapter { platform: Platform, message: String },

    /// A feature is unavailable on the current platform.
    #[error("Feature '{feature}' is not available on {platform}")]
    Unavailable { feature: String, platform: Platform },

    /// Inference error — API call failed, timeout, bad response.
    #[error("Inference error: {message}")]
    Inference { message: String },

    /// Filesystem error — file not found, permission denied, etc.
    #[error("Filesystem error at {}: {message}", path.display())]
    Filesystem { message: String, path: PathBuf },

    /// Memory/learning persistence error.
    #[error("Memory error: {message}")]
    Memory { message: String },

    /// Skill loading or execution error.
    #[error("Skill error ({skill}): {message}")]
    Skill { skill: String, message: String },

    /// Git sync error.
    #[error("Sync error: {message}")]
    Sync { message: String },
}
