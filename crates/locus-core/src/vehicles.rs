//! Which delegation vehicles this machine can actually reach.
//!
//! Work leaves an orchestrator session through a *vehicle*. There are four, in
//! strict preference order, and the preference is about observability: a real
//! allele session is visible in the sidebar, interruptible and addressable,
//! which a subagent is not. That argument is unchanged. What this module adds
//! is the answer to a question the argument never addressed — what happens when
//! the preferred vehicle is not there.
//!
//! # The probe is not what removes the dead end
//!
//! It is tempting to read this module as "the thing that stops Locus denying
//! into a dead end". It is not. The only thing that can turn an executable
//! option into a dead end is the `PreToolUse` denial, so the chain terminates
//! if and only if that denial is guaranteed to release — see
//! [`NO_VEHICLE_ESCAPE`]. The probe's job is narrower and worth stating plainly:
//! it makes the *default* correct.
//!
//! # What the probe actually observes
//!
//! [`VehicleAvailability::probe`] reports a fact about the **machine**, not
//! about the calling session. `connect(2)` succeeding on the allele control
//! socket proves the Allele app is up and accepting; it does not prove the
//! `allele_*` MCP tools are registered in whichever Claude Code session is
//! asking. Those are two different facts and they disagree routinely — a
//! session started before the app, or one whose MCP registration failed, sees
//! no allele tools while the socket is perfectly healthy.
//!
//! Every message this module produces therefore states which fact it is
//! reporting, so a session that finds itself on the wrong side of the
//! disagreement can recognise it rather than trusting it.
//!
//! # Reachable, not present
//!
//! A socket *file* survives the process that created it. Checking
//! `Path::exists` would report a crashed app as available, which is the failure
//! mode DEV-579's own tool descriptions warned about: registration without a
//! running app fails at first call. Only a completed `connect(2)` distinguishes
//! them.
//!
//! Note what this deliberately does not distinguish: an app that is *up but
//! busy* — every dispatch slot taken — still accepts on the socket and is still
//! reported reachable. That is correct. A full slot cap is backpressure, not
//! absence, and it must make a caller wait rather than unlock a less observable
//! vehicle.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// Environment override for the allele control socket, for tests and for
/// anyone running the app out of a non-default home.
pub const ALLELE_SOCKET_ENV: &str = "LOCUS_ALLELE_SOCKET";

/// The marker a caller includes to assert, from its own vantage point, that no
/// sanctioned vehicle is usable — releasing the `PreToolUse` denial.
///
/// This is the release condition that makes the routing chain terminate. The
/// hook probes the filesystem; the model observes its own toolset; when those
/// two disagree the model is the one holding the better evidence, and a gate
/// that cannot be contradicted by better evidence is a gate that can be
/// permanently wrong. Spelled in the same shape as the Stop gate's
/// `locus: skip`, and it lands in the transcript, so using it is a recorded
/// act rather than a silent one.
pub const NO_VEHICLE_ESCAPE: &str = "locus:no-allele";

/// Ceiling on the reachability probe.
///
/// `connect(2)` to a unix socket normally settles immediately — accepted, or
/// `ECONNREFUSED` against a stale path. The exception is a listener whose
/// accept backlog is full, which blocks on Linux. This probe runs on every
/// `PreToolUse`, so an unbounded call there would stall every tool call in the
/// session behind a busy app.
const PROBE_TIMEOUT: Duration = Duration::from_millis(250);

/// How a unit of work leaves the orchestrator session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vehicle {
    /// A real allele session: own workspace, own branch, addressable,
    /// interruptible. The default, and the only vehicle that is none of
    /// hidden, unaddressable or uninterruptible.
    Allele,
    /// `locus delegate run` against OpenCode. Read-only, no workspace, no
    /// branch, no conversation.
    OpenCode,
    /// The platform's own `Task` / `Agent` subagent. Permitted only when
    /// neither sanctioned vehicle is available, and never silently.
    NativeSubagent,
    /// Do the work in this session. Correct only when the work never warranted
    /// delegation in the first place.
    Inline,
}

impl Vehicle {
    /// Stable identifier used in logs and messages.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Allele => "allele",
            Self::OpenCode => "opencode",
            Self::NativeSubagent => "native_subagent",
            Self::Inline => "inline",
        }
    }

    /// Position in the routing table, 1 being the most preferred.
    pub fn tier(&self) -> u8 {
        match self {
            Self::Allele => 1,
            Self::OpenCode => 2,
            Self::NativeSubagent => 3,
            Self::Inline => 4,
        }
    }

    /// How a caller actually invokes this vehicle.
    pub fn invocation(&self) -> &'static str {
        match self {
            Self::Allele => "allele_sessions_create",
            Self::OpenCode => "locus delegate run --backend opencode",
            Self::NativeSubagent => "the platform's native Task/Agent tool",
            Self::Inline => "this session, directly",
        }
    }

    /// True for the two vehicles the Algorithm sanctions without qualification.
    pub fn is_sanctioned(&self) -> bool {
        matches!(self, Self::Allele | Self::OpenCode)
    }
}

/// What a probe of this machine found.
///
/// Deliberately a plain pair of booleans rather than an enum: the two vehicles
/// fail independently and the doctor reports both, so collapsing them into a
/// single "best" value at construction time would throw away the half a reader
/// needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VehicleAvailability {
    /// The Allele control socket accepted a connection.
    pub allele: bool,
    /// The OpenCode binary resolves and its credential file is present.
    pub opencode: bool,
}

impl VehicleAvailability {
    /// Neither sanctioned vehicle is available.
    pub const NONE: Self = Self {
        allele: false,
        opencode: false,
    };

    /// Probe this machine.
    ///
    /// Cheap enough for `PreToolUse`: one bounded `connect(2)` and a walk of
    /// `PATH` entries, no subprocess.
    pub fn probe() -> Self {
        Self {
            allele: allele_reachable(),
            opencode: opencode_available(),
        }
    }

    /// The highest-priority vehicle whose preconditions this machine satisfies.
    ///
    /// Never returns [`Vehicle::Inline`]: whether work warrants delegation at
    /// all is a judgement about the work, which a probe of the machine cannot
    /// make.
    pub fn preferred(&self) -> Vehicle {
        if self.allele {
            Vehicle::Allele
        } else if self.opencode {
            Vehicle::OpenCode
        } else {
            Vehicle::NativeSubagent
        }
    }

    /// True while the denial has somewhere better to send the caller.
    ///
    /// This is the whole gate condition. When it is false the `PreToolUse`
    /// denial must not fire, because there is nothing left to route to and
    /// denying would be denying into a dead end.
    pub fn has_sanctioned_vehicle(&self) -> bool {
        self.allele || self.opencode
    }

    /// The once-per-session availability notice.
    ///
    /// Advisory only, and says so. Reachability at session start is not
    /// reachability forty minutes later — an app can come up, a credential can
    /// expire — so this text must never be the thing a decision is made on. The
    /// hook re-probes at deny time and is the sole authority.
    pub fn session_notice(&self) -> String {
        match (self.allele, self.opencode) {
            (true, _) => format!(
                "Locus delegation: the Allele app is reachable on this machine ({}), \
                 so dispatch through `allele_sessions_create` — that is the happy path. \
                 This is a fact about the machine, not about this session: if the \
                 `allele_*` tools are absent from your toolset, this session is not \
                 connected to the running app, and you should say so and use \
                 `locus delegate run` instead. Availability is re-checked when it \
                 matters; do not treat this line as still true an hour from now.",
                describe_socket()
            ),
            (false, true) => format!(
                "Locus delegation is DEGRADED: the Allele app is not reachable on this \
                 machine ({} is not accepting connections), so dispatch falls back to \
                 `locus delegate run --backend opencode`. You lose the workspace, the \
                 branch and the conversation — say so when you use it. Native subagents \
                 are not needed while OpenCode is available.",
                describe_socket()
            ),
            (false, false) => format!(
                "Locus delegation is DEGRADED: neither sanctioned vehicle is available \
                 on this machine — the Allele app is not reachable ({} is not accepting \
                 connections) and OpenCode is not usable (binary or credential missing). \
                 Native `Task`/`Agent` subagents are therefore PERMITTED as the \
                 last-resort vehicle. Before you dispatch one, tell the user plainly \
                 that delegation has degraded to a hidden subagent — no workspace, no \
                 branch, no conversation, not interruptible. If the work needs a real \
                 session, the right move is to stop and say delegation is unavailable, \
                 not to quietly absorb it into this one.",
                describe_socket()
            ),
        }
    }

    /// One line per vehicle, for `locus doctor`.
    ///
    /// Both lines are informational whatever they say. A machine with no Allele
    /// is a supported configuration, not a defect, and reporting it as a
    /// warning would train the reader to ignore the section.
    pub fn doctor_lines(&self) -> Vec<String> {
        vec![
            format!(
                "Allele (tier 1, {}) — {}",
                Vehicle::Allele.invocation(),
                if self.allele {
                    format!("reachable at {}", describe_socket())
                } else {
                    format!(
                        "not reachable ({} is not accepting connections)",
                        describe_socket()
                    )
                }
            ),
            format!(
                "OpenCode (tier 2, {}) — {}",
                Vehicle::OpenCode.invocation(),
                if self.opencode {
                    "available".to_string()
                } else {
                    "not available (binary not on PATH, or credential missing)".to_string()
                }
            ),
            format!(
                "Routing — delegation goes to tier {} ({}). {}",
                self.preferred().tier(),
                self.preferred().as_str(),
                if self.has_sanctioned_vehicle() {
                    "Native subagents are denied while a sanctioned vehicle is reachable."
                } else {
                    "No sanctioned vehicle is reachable, so native subagents are permitted."
                }
            ),
        ]
    }
}

/// Where the allele control socket lives.
pub fn allele_socket_path() -> Option<PathBuf> {
    if let Ok(raw) = std::env::var(ALLELE_SOCKET_ENV) {
        if !raw.is_empty() {
            return Some(PathBuf::from(raw));
        }
    }
    dirs::home_dir().map(|h| h.join(".allele").join("control.sock"))
}

fn describe_socket() -> String {
    allele_socket_path()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "~/.allele/control.sock".to_string())
}

/// True when the Allele app is up and accepting on its control socket.
pub fn allele_reachable() -> bool {
    allele_socket_path().is_some_and(|p| socket_accepts(&p))
}

/// `connect(2)`, bounded.
///
/// The connect runs on a worker thread so the caller can give up. A thread left
/// blocked on a wedged socket costs nothing: hooks are one-shot processes that
/// exit within milliseconds of this returning, and the thread dies with them.
#[cfg(unix)]
fn socket_accepts(path: &Path) -> bool {
    use std::os::unix::net::UnixStream;

    let path = path.to_path_buf();
    let (tx, rx) = std::sync::mpsc::channel();
    if std::thread::Builder::new()
        .name("locus-vehicle-probe".into())
        .spawn(move || {
            let _ = tx.send(UnixStream::connect(&path).is_ok());
        })
        .is_err()
    {
        return false;
    }
    rx.recv_timeout(PROBE_TIMEOUT).unwrap_or(false)
}

#[cfg(not(unix))]
fn socket_accepts(_path: &Path) -> bool {
    // Allele is a unix-socket product. On any other platform the honest answer
    // is "not reachable", which routes to the fallback rather than to a lie.
    false
}

/// True when `locus delegate run --backend opencode` has what it needs.
///
/// Two independent preconditions, both of which have been observed missing in
/// the field: the binary (DEV-508's machine had no OpenCode at all) and the
/// credential (DEV-505's 401).
pub fn opencode_available() -> bool {
    opencode_binary_present() && opencode_auth_path().is_some_and(|p| p.exists())
}

/// Resolve the OpenCode binary without spawning a subprocess.
///
/// `which` would cost a process spawn on every `PreToolUse`. Walking `PATH`
/// in-process is the same answer for a fraction of the cost.
///
/// The extra candidate is not belt-and-braces. A hook inherits Claude Code's
/// environment, not the user's login shell, so an OpenCode installed by its own
/// installer into `~/.opencode/bin` — the default — is frequently absent from
/// the `PATH` the hook sees while being perfectly present for the user. Missing
/// it would report tier 2 unavailable and hand the caller a needless
/// degradation.
fn opencode_binary_present() -> bool {
    if program_on_path("opencode") {
        return true;
    }
    dirs::home_dir()
        .map(|h| h.join(".opencode").join("bin").join("opencode"))
        .is_some_and(|p| is_executable_file(&p))
}

fn program_on_path(program: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|dir| is_executable_file(&dir.join(program)))
}

#[cfg(unix)]
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|m| m.is_file())
        .unwrap_or(false)
}

/// Where OpenCode keeps the credential the delegation path depends on.
///
/// `$XDG_DATA_HOME/opencode/auth.json`, falling back to
/// `~/.local/share/opencode/auth.json`. Both candidates are probed because the
/// rest of the stack does not agree on the answer — see the same note on
/// `doctor::canonical_opencode_auth`, which this deliberately mirrors rather
/// than importing so that `locus-core` stays free of a CLI dependency.
/// Collapsing the copies is DEV-612.
pub fn opencode_auth_path() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = std::env::var_os("XDG_DATA_HOME") {
        if !dir.is_empty() {
            candidates.push(PathBuf::from(dir).join("opencode").join("auth.json"));
        }
    }
    if let Some(home) = dirs::home_dir() {
        candidates.push(
            home.join(".local")
                .join("share")
                .join("opencode")
                .join("auth.json"),
        );
    }
    candidates
        .iter()
        .find(|p| p.exists())
        .cloned()
        .or_else(|| candidates.into_iter().next())
}

/// True when text carries the escape marker that releases the denial.
pub fn carries_escape(text: &str) -> bool {
    text.contains(NO_VEHICLE_ESCAPE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferred_walks_the_table_in_order() {
        assert_eq!(
            VehicleAvailability {
                allele: true,
                opencode: true
            }
            .preferred(),
            Vehicle::Allele
        );
        assert_eq!(
            VehicleAvailability {
                allele: false,
                opencode: true
            }
            .preferred(),
            Vehicle::OpenCode
        );
        assert_eq!(
            VehicleAvailability::NONE.preferred(),
            Vehicle::NativeSubagent
        );
    }

    #[test]
    fn tiers_are_ordered_and_only_the_top_two_are_sanctioned() {
        assert_eq!(Vehicle::Allele.tier(), 1);
        assert_eq!(Vehicle::OpenCode.tier(), 2);
        assert_eq!(Vehicle::NativeSubagent.tier(), 3);
        assert_eq!(Vehicle::Inline.tier(), 4);

        assert!(Vehicle::Allele.is_sanctioned());
        assert!(Vehicle::OpenCode.is_sanctioned());
        assert!(!Vehicle::NativeSubagent.is_sanctioned());
        assert!(!Vehicle::Inline.is_sanctioned());
    }

    /// The gate condition, stated once so it cannot drift: the denial fires
    /// while and only while something better is reachable.
    #[test]
    fn the_denial_has_a_target_only_while_a_sanctioned_vehicle_is_up() {
        assert!(VehicleAvailability {
            allele: true,
            opencode: false
        }
        .has_sanctioned_vehicle());
        assert!(VehicleAvailability {
            allele: false,
            opencode: true
        }
        .has_sanctioned_vehicle());
        assert!(!VehicleAvailability::NONE.has_sanctioned_vehicle());
    }

    #[cfg(unix)]
    #[test]
    fn a_listening_socket_is_reachable() {
        use std::os::unix::net::UnixListener;

        let dir = std::env::temp_dir().join(format!("locus-vehicle-live-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("control.sock");
        let _listener = UnixListener::bind(&path).unwrap();

        assert!(socket_accepts(&path));

        std::fs::remove_dir_all(&dir).ok();
    }

    /// The case that makes existence the wrong test. A crashed app leaves its
    /// socket file behind; `Path::exists` would call that healthy.
    #[cfg(unix)]
    #[test]
    fn a_stale_socket_file_is_not_reachable() {
        let dir = std::env::temp_dir().join(format!("locus-vehicle-stale-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("control.sock");

        {
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
            drop(listener);
        }
        // The listener is gone; on Unix the inode is not.
        assert!(path.exists(), "the socket file should outlive its listener");
        assert!(
            !socket_accepts(&path),
            "a socket nothing is listening on must not read as reachable"
        );

        std::fs::remove_dir_all(&dir).ok();
    }

    #[cfg(unix)]
    #[test]
    fn an_absent_socket_is_not_reachable() {
        let path = std::env::temp_dir().join("locus-vehicle-does-not-exist.sock");
        std::fs::remove_file(&path).ok();
        assert!(!socket_accepts(&path));
    }

    #[test]
    fn every_notice_names_a_next_step() {
        for availability in [
            VehicleAvailability {
                allele: true,
                opencode: true,
            },
            VehicleAvailability {
                allele: false,
                opencode: true,
            },
            VehicleAvailability::NONE,
        ] {
            let notice = availability.session_notice();
            assert!(
                notice.contains("allele_sessions_create")
                    || notice.contains("locus delegate run")
                    || notice.contains("PERMITTED"),
                "notice names no vehicle: {notice}"
            );
        }
    }

    /// The acceptance criterion in one assertion: a machine with nothing
    /// available must still say what to do, and what it says must be the
    /// permitted last resort — not silence, and not a prohibition.
    #[test]
    fn the_no_vehicle_notice_permits_the_last_resort_and_names_the_cost() {
        let notice = VehicleAvailability::NONE.session_notice();
        assert!(notice.contains("PERMITTED"));
        assert!(notice.contains("Task"));
        assert!(notice.contains("no branch"));
        assert!(notice.contains("stop and say delegation is unavailable"));
    }

    #[test]
    fn doctor_reports_both_vehicles_and_the_resulting_route() {
        let lines = VehicleAvailability::NONE.doctor_lines();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("Allele (tier 1"));
        assert!(lines[1].starts_with("OpenCode (tier 2"));
        assert!(lines[2].contains("native subagents are permitted"));
    }

    /// Serialised against the other env-reading test by the mutex below:
    /// `set_var` is process-global and the test harness runs threads.
    #[test]
    fn the_socket_path_honours_its_environment_override() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let previous = std::env::var(ALLELE_SOCKET_ENV).ok();

        std::env::set_var(ALLELE_SOCKET_ENV, "/tmp/locus-override.sock");
        assert_eq!(
            allele_socket_path(),
            Some(PathBuf::from("/tmp/locus-override.sock"))
        );

        // Empty is not an override — it falls back rather than probing "".
        std::env::set_var(ALLELE_SOCKET_ENV, "");
        assert_ne!(allele_socket_path(), Some(PathBuf::new()));

        match previous {
            Some(v) => std::env::set_var(ALLELE_SOCKET_ENV, v),
            None => std::env::remove_var(ALLELE_SOCKET_ENV),
        }
    }

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn escape_marker_is_recognised_inside_surrounding_prose() {
        assert!(carries_escape(
            "no allele_* tools in this session, locus:no-allele, proceeding"
        ));
        assert!(!carries_escape("a perfectly ordinary research task"));
    }
}
