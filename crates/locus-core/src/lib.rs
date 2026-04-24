//! # Locus Core
//!
//! Core types, traits, and interfaces for the Locus agentic workflow framework.
//!
//! This crate defines the contract that all other Locus crates depend on:
//!
//! - [`Platform`] — exhaustive enum of supported AI coding platforms
//! - [`PlatformAdapter`] — the trait every platform adapter implements
//! - [`CapabilityManifest`] — declares what a platform supports
//! - [`LocusConfig`] — the canonical `locus.yaml` configuration
//! - Events — lifecycle and hook events that adapters translate
//! - Skills — skill, workflow, tool, and agent type definitions
//! - Memory — learning, project memory, and context pack schemas
//! - Errors — structured error types for the entire system
//!
//! ## Design Principles
//!
//! - **Dependency inversion**: this crate defines interfaces, never implementations.
//!   Adapter crates depend on `locus-core`, never the reverse.
//! - **Exhaustive matching**: the `Platform` enum ensures every adapter, config generator,
//!   and capability check handles all platforms. Adding a platform causes compiler errors
//!   everywhere it isn't handled.
//! - **Honest degradation**: features requiring unsupported platform capabilities are
//!   explicitly marked unavailable via `CapabilityManifest`, never silently degraded.

pub mod adapter;
pub mod agents;
pub mod capabilities;
pub mod config;
pub mod delegation;
pub mod error;
pub mod events;
pub mod memory;
pub mod platform;
pub mod skill;

// Re-export primary types at crate root for convenience.
pub use adapter::PlatformAdapter;
pub use agents::{ComposedAgent, Trait, Traits};
pub use capabilities::CapabilityManifest;
pub use config::{DelegationConfig, DelegationDefaults, LocusConfig};
pub use delegation::{
    DelegationBackend, DelegationMode, DelegationRequest, DelegationResult, DelegationStatus,
    DelegationTaskKind,
};
pub use error::LocusError;
pub use events::{EventKind, HookEvent, LifecycleEvent};
pub use platform::Platform;
