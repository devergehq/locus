//! Stop-hook verifier — enforce skill invocation, and measure itself.
//!
//! Ported from `hooks/lib/verify_stop.py` (DEV-579, DEV-580) so that every hook
//! runs through one mechanism in one language. The Python version needed
//! `python3`, which macOS does not ship without Command Line Tools, and its
//! wrapper failed open — so on such a machine the gate never fired and the
//! activation log stayed empty, with nothing to say so. Zero-by-absence read
//! exactly like zero-by-compliance, inside the one mechanism built to measure
//! whether the Algorithm runs.
//!
//! Behaviour is unchanged from the Python. Two jobs, one object:
//!
//! 1. Enforcement. A turn that classified itself non-trivial and then never
//!    invoked the `locus-algorithm` skill is blocked exactly once.
//!
//!    The gate deliberately does **not** fire on a missing classification line.
//!    The line is nearly free to emit; the skill invocation is the expensive
//!    behaviour. Gating on either would teach the model to produce the cheap
//!    half and improve the block rate for reasons that are not improvement.
//!    The line is still recorded every turn — a signal, never a gate.
//!
//! 2. Measurement. Each turn appends a `turn` record; a blocked turn appends a
//!    `recovery` record once the model continues. They share a `prompt_id`.
//!    Without that split, a turn that was blocked and then did the right thing
//!    is indistinguishable from one that simply failed.
//!
//! The record shape is byte-compatible with the Python format — field order
//! included, which is why these are `#[derive(Serialize)]` structs rather than
//! `serde_json::json!` maps. `serde_json::Map` is a `BTreeMap` by default and
//! would emit keys alphabetically; a derived struct emits them in declaration
//! order. Patrick charts this file, so a silent reordering would be a real
//! break dressed as a refactor.

use std::path::{Path, PathBuf};

use chrono::SecondsFormat;

/// Written by the user, never by the model — a model must not be able to
/// switch off its own check by emitting the phrase in its reply.
const ESCAPE_PHRASE: &str = "locus: skip";

const SKILL_ID: &str = "locus-algorithm";

const TRIVIAL: &str = "**Classification: Trivial**";
const NON_TRIVIAL: &str = "**Classification: Non-trivial**";

/// A blocked turn whose recovery Stop never arrives — a max-turns abort, a user
/// interrupt — leaves its marker behind. Nothing reads a stale marker (prompt
/// ids are UUIDs), but they would accumulate forever, so each write sweeps the
/// old ones. An hour is far longer than any turn and far shorter than "forever".
const MARKER_TTL_SECONDS: u64 = 3600;

/// One line of the activation log.
///
/// Field order here *is* the on-disk format. Do not reorder.
#[derive(serde::Serialize)]
struct ActivationRecord<'a> {
    ts: String,
    session_id: &'a str,
    prompt_id: &'a str,
    event: &'a str,
    classification: Option<&'a str>,
    skill_fired: bool,
    escaped: bool,
    blocked: bool,
    outcome: &'a str,
    reason: Option<&'a str>,
}

/// What the Stop hook should do once the verifier has run.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// End the turn normally.
    Allow,
    /// Block once, feeding this reason back to the model on stderr.
    Block(String),
}

/// Which classification line the turn opened with, if any.
///
/// Substring rather than prefix: a turn may legitimately lead with a tool
/// result or a short preamble, and the criterion is that the line is present
/// and unambiguous, not that it is byte zero.
fn classification(message: &str) -> Option<&'static str> {
    // `**Classification: Non-trivial**` does not contain the trivial marker —
    // the casing differs — so the two are genuinely exclusive.
    if message.contains(NON_TRIVIAL) {
        Some("non-trivial")
    } else if message.contains(TRIVIAL) {
        Some("trivial")
    } else {
        None
    }
}

/// `stop_hook_active` arrives as a JSON bool, but tolerate a string.
fn truthy(value: Option<&serde_json::Value>) -> bool {
    match value {
        Some(serde_json::Value::Bool(b)) => *b,
        Some(serde_json::Value::String(s)) => s.trim().eq_ignore_ascii_case("true"),
        _ => false,
    }
}

/// Where the activation log lives.
///
/// `LOCUS_ACTIVATION_LOG_DIR` first so tests can redirect it. Then the user's
/// configured data directory, exposed to hooks as `CLAUDE_PLUGIN_OPTION_<KEY>`
/// for each `userConfig` key. Then the plugin's own data directory, which
/// always exists. If none resolve we simply do not log — enforcement still works.
fn log_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("LOCUS_ACTIVATION_LOG_DIR") {
        if !dir.is_empty() {
            return Some(PathBuf::from(shellexpand_home(&dir)));
        }
    }
    for var in ["CLAUDE_PLUGIN_OPTION_DATADIR", "CLAUDE_PLUGIN_DATA"] {
        if let Ok(base) = std::env::var(var) {
            if !base.is_empty() {
                return Some(PathBuf::from(shellexpand_home(&base)).join("activation"));
            }
        }
    }
    None
}

fn shellexpand_home(raw: &str) -> String {
    match raw.strip_prefix("~/") {
        Some(rest) => dirs::home_dir()
            .map(|h| h.join(rest).display().to_string())
            .unwrap_or_else(|| raw.to_string()),
        None => raw.to_string(),
    }
}

fn append_record(record: &ActivationRecord<'_>) {
    let Some(dir) = log_dir() else { return };
    // Losing a log line must never cost the user their turn.
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let month = chrono::Utc::now().format("%Y-%m").to_string();
    let path = dir.join(format!("activation-{}.jsonl", month));
    let Ok(mut line) = serde_json::to_string(record) else {
        return;
    };
    line.push('\n');
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// Where the "we blocked this prompt" marker lives.
///
/// `stop_hook_active` says only that *some* Stop hook blocked — not that it was
/// ours. Another plugin's hook blocking would otherwise make us append a
/// recovery record for a turn we never touched, inventing data in the one file
/// that is supposed to be trustworthy. The marker is what tells them apart.
fn marker_path(prompt_id: &str) -> Option<PathBuf> {
    if prompt_id.is_empty() {
        return None;
    }
    let safe: String = prompt_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    Some(log_dir()?.join("pending").join(format!("{}.marker", safe)))
}

fn prune_markers(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(MARKER_TTL_SECONDS));
    let Some(cutoff) = cutoff else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("marker") {
            continue;
        }
        if let Ok(modified) = entry.metadata().and_then(|m| m.modified()) {
            if modified < cutoff {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
}

fn set_marker(prompt_id: &str) {
    let Some(path) = marker_path(prompt_id) else {
        return;
    };
    let Some(dir) = path.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    prune_markers(dir);
    let _ = std::fs::write(&path, b"");
}

/// Consume the marker, returning whether we were the hook that blocked.
fn take_marker(prompt_id: &str) -> bool {
    let Some(path) = marker_path(prompt_id) else {
        return false;
    };
    if !path.exists() {
        return false;
    }
    let _ = std::fs::remove_file(&path);
    true
}

/// Walk the session transcript to the user row carrying `prompt_id`, then
/// inspect every assistant row after it.
///
/// Returns empty/false rather than erroring if the transcript is missing or
/// shaped unexpectedly — an unreadable transcript must not become a block.
fn scan_transcript(path: &str, prompt_id: &str) -> (String, bool) {
    let mut prompt_text = String::new();
    let mut skill_fired = false;

    if path.is_empty() || !Path::new(path).exists() {
        return (prompt_text, skill_fired);
    }
    let Ok(raw) = std::fs::read_to_string(path) else {
        return (prompt_text, skill_fired);
    };

    let rows: Vec<serde_json::Value> = raw
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();

    let mut start = None;
    for (index, row) in rows.iter().enumerate() {
        if row.get("type").and_then(|v| v.as_str()) != Some("user") {
            continue;
        }
        if row.get("promptId").and_then(|v| v.as_str()) != Some(prompt_id) {
            continue;
        }
        // Hook-injected context is recorded as a user row too; it is not what
        // the human typed, so it cannot carry the escape phrase.
        if row.get("isMeta").and_then(|v| v.as_bool()).unwrap_or(false) {
            continue;
        }
        if start.is_none() {
            start = Some(index);
        }
        if let Some(text) = row
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
        {
            prompt_text.push_str(text);
        }
    }

    let Some(start) = start else {
        return (prompt_text, skill_fired);
    };

    for row in &rows[start..] {
        if row.get("type").and_then(|v| v.as_str()) != Some("assistant") {
            continue;
        }
        let Some(blocks) = row
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_array())
        else {
            continue;
        };
        for block in blocks {
            if block.get("type").and_then(|v| v.as_str()) != Some("tool_use") {
                continue;
            }
            // Substring, not equality, and deliberately so. A live session
            // invokes this as `Skill(skill="locus:locus-algorithm")` — Claude
            // Code namespaces plugin skills — while a bare `locus-algorithm`
            // and a direct Read of the SKILL.md are both legitimate too.
            // Matching the exact id would miss the form real sessions use.
            let input = block.get("input").cloned().unwrap_or(serde_json::json!({}));
            if serde_json::to_string(&input)
                .unwrap_or_default()
                .contains(SKILL_ID)
            {
                skill_fired = true;
            }
        }
    }

    (prompt_text, skill_fired)
}

fn now_iso() -> String {
    // Python wrote `datetime.now(timezone.utc).isoformat()`, i.e. microsecond
    // precision and a `+00:00` offset. Match it exactly — the log format is a
    // contract, not an implementation detail.
    chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Micros, false)
}

/// Run the verifier against a Stop event.
pub fn verify(event: &serde_json::Value) -> Verdict {
    let prompt_id = event
        .get("prompt_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let session_id = event
        .get("session_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let message = event
        .get("last_assistant_message")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let transcript = event
        .get("transcript_path")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let (prompt_text, skill_fired) = scan_transcript(transcript, prompt_id);
    let escaped = prompt_text.to_lowercase().contains(ESCAPE_PHRASE);
    let class = classification(message);

    // The one-block-per-turn ceiling. Claude Code sets this on the Stop that
    // follows a block, so honouring it makes a deadlock structurally impossible
    // however wrong the gate logic gets. This pass never blocks; its only job is
    // to record what the model did with the second chance — and only if the
    // block was ours, which the marker establishes.
    if truthy(event.get("stop_hook_active")) {
        if take_marker(prompt_id) {
            append_record(&ActivationRecord {
                ts: now_iso(),
                session_id,
                prompt_id,
                event: "recovery",
                classification: class,
                skill_fired,
                escaped,
                blocked: false,
                outcome: if skill_fired { "recovered" } else { "unrecovered" },
                reason: None,
            });
        }
        return Verdict::Allow;
    }

    let reason = if !escaped && class == Some("non-trivial") && !skill_fired {
        Some(
            "Locus: you classified this request non-trivial but never invoked the \
             `locus-algorithm` skill. Invoke it and follow its phases, or reclassify \
             the request as trivial if that is what it is."
                .to_string(),
        )
    } else {
        None
    };

    let outcome = match (&reason, escaped) {
        (Some(_), _) => "blocked",
        (None, true) => "escaped",
        (None, false) => "passed",
    };

    append_record(&ActivationRecord {
        ts: now_iso(),
        session_id,
        prompt_id,
        event: "turn",
        classification: class,
        skill_fired,
        escaped,
        blocked: reason.is_some(),
        outcome,
        reason: reason.as_deref(),
    });

    match reason {
        Some(r) => {
            set_marker(prompt_id);
            Verdict::Block(r)
        }
        None => Verdict::Allow,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // `verify` reads process-wide environment to find the log directory, so the
    // tests that redirect it cannot run concurrently. Rust runs tests in
    // threads by default, so serialise them here rather than requiring
    // `--test-threads=1` and hoping nobody forgets.
    // Poison-tolerant on purpose: one failing test must not cascade into
    // nine misleading PoisonError failures that hide the real one.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct Case {
        _dir: tempfile::TempDir,
        log: PathBuf,
        transcript: PathBuf,
    }

    fn case(prompt: &str, skill: Option<&str>) -> Case {
        let dir = tempfile::tempdir().expect("tempdir");
        let log = dir.path().join("log");
        let transcript = dir.path().join("t.jsonl");

        let mut rows = vec![
            serde_json::json!({"type":"user","promptId":"P1","isMeta":true,
                               "message":{"role":"user","content":"injected"}}),
            serde_json::json!({"type":"user","promptId":"P1",
                               "message":{"role":"user","content":prompt}}),
        ];
        if let Some(id) = skill {
            rows.push(serde_json::json!({"type":"assistant","message":{"role":"assistant",
                "content":[{"type":"tool_use","name":"Skill","input":{"skill":id}}]}}));
        }
        let body = rows
            .iter()
            .map(|r| r.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        std::fs::write(&transcript, body).unwrap();

        std::env::set_var("LOCUS_ACTIVATION_LOG_DIR", &log);
        Case {
            _dir: dir,
            log,
            transcript,
        }
    }

    fn stop_event(c: &Case, message: &str, active: bool) -> serde_json::Value {
        serde_json::json!({
            "session_id": "S1",
            "prompt_id": "P1",
            "hook_event_name": "Stop",
            "transcript_path": c.transcript.to_str().unwrap(),
            "last_assistant_message": message,
            "stop_hook_active": active,
        })
    }

    fn records(c: &Case) -> Vec<serde_json::Value> {
        let Ok(entries) = std::fs::read_dir(&c.log) else {
            return vec![];
        };
        let mut out = vec![];
        for e in entries.flatten() {
            if e.path().extension().and_then(|x| x.to_str()) != Some("jsonl") {
                continue;
            }
            let text = std::fs::read_to_string(e.path()).unwrap();
            for line in text.lines().filter(|l| !l.trim().is_empty()) {
                out.push(serde_json::from_str(line).unwrap());
            }
        }
        out
    }

    fn blocked(v: &Verdict) -> bool {
        matches!(v, Verdict::Block(_))
    }

    // ---------------------------------------------------------- the gate --

    #[test]
    fn blocks_non_trivial_with_no_skill_invocation() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        let v = verify(&stop_event(&c, "**Classification: Non-trivial**\n\nwinging it", false));
        assert!(blocked(&v));
        if let Verdict::Block(r) = v {
            assert!(
                r.contains("locus-algorithm"),
                "the reason must name the skill, not the classification line: {r}"
            );
        }
    }

    #[test]
    fn allows_non_trivial_when_the_skill_fired() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", Some("locus-algorithm"));
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Non-trivial**\n\nOBSERVE", false)),
            Verdict::Allow
        );
    }

    /// A live session invokes the skill as `locus:locus-algorithm` — Claude Code
    /// namespaces plugin skills. Matching the exact id would miss the only form
    /// that actually occurs in production.
    #[test]
    fn detects_the_namespaced_skill_id() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", Some("locus:locus-algorithm"));
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Non-trivial**\n\nOBSERVE", false)),
            Verdict::Allow
        );
    }

    /// DEV-580: the classification line is a logged signal, never a gate.
    /// Blocking on a missing line would reward emitting the cheap half.
    #[test]
    fn a_missing_classification_line_never_blocks() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        assert_eq!(verify(&stop_event(&c, "all done", false)), Verdict::Allow);
    }

    #[test]
    fn a_trivial_classification_never_blocks() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("rename a variable", None);
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Trivial**\n\ndone", false)),
            Verdict::Allow
        );
    }

    // -------------------------------------------------------- the guards --

    #[test]
    fn ceiling_never_blocks_twice_in_one_turn() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Non-trivial**\n\nstill nothing", true)),
            Verdict::Allow
        );
    }

    #[test]
    fn escape_phrase_in_the_user_prompt_is_honoured() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("just do it, locus: skip", None);
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Non-trivial**\n\nno skill", false)),
            Verdict::Allow
        );
    }

    #[test]
    fn escape_phrase_is_case_insensitive() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("just do it, LOCUS: SKIP", None);
        assert_eq!(
            verify(&stop_event(&c, "**Classification: Non-trivial**\n\nno skill", false)),
            Verdict::Allow
        );
    }

    /// The model must not be able to switch off its own check by emitting the
    /// phrase in its reply — only the user's prompt counts.
    #[test]
    fn the_model_cannot_escape_for_itself() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        let v = verify(&stop_event(
            &c,
            "**Classification: Non-trivial**\n\nlocus: skip — I decided this is fine",
            false,
        ));
        assert!(blocked(&v));
    }

    /// An unreadable transcript is not a free pass, and never was.
    ///
    /// The Python behaved identically: `scan_transcript` returns
    /// `("", False)`, so a turn that declared itself non-trivial still blocks
    /// because nothing can confirm the skill fired. The old shell test named
    /// this case "fails open on an unreadable transcript" but passed a
    /// *trivial* classification, so it only ever proved that trivial turns do
    /// not block — a name claiming coverage the assertion did not have.
    ///
    /// Both halves are pinned here so the real behaviour is stated rather than
    /// implied. The cost is bounded to one turn by the ceiling.
    #[test]
    fn an_unreadable_transcript_matches_the_python_behaviour() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);

        let mut trivial = stop_event(&c, "**Classification: Trivial**\n\ndone", false);
        trivial["transcript_path"] = serde_json::json!("/nonexistent/path.jsonl");
        assert_eq!(verify(&trivial), Verdict::Allow);

        let mut non_trivial = stop_event(&c, "**Classification: Non-trivial**\n\nx", false);
        non_trivial["transcript_path"] = serde_json::json!("/nonexistent/path.jsonl");
        assert!(
            blocked(&verify(&non_trivial)),
            "a non-trivial turn with no confirmable skill invocation blocks, \
             transcript readable or not — unchanged from the Python"
        );
    }

    // ------------------------------------------------- the activation log --

    /// The on-disk format is a contract — Patrick charts this file. Field order
    /// included: a derived struct emits declaration order, whereas a
    /// `serde_json` map would emit keys alphabetically and silently break it.
    #[test]
    fn turn_record_field_order_matches_the_python_format() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nx", false));

        let path = std::fs::read_dir(&c.log)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .find(|p| p.extension().and_then(|x| x.to_str()) == Some("jsonl"))
            .expect("a log file");
        let line = std::fs::read_to_string(path).unwrap();
        let first = line.lines().next().unwrap();

        let keys: Vec<&str> = first
            .trim_start_matches('{')
            .split(",\"")
            .map(|seg| seg.trim_start_matches('"').split('"').next().unwrap())
            .collect();

        assert_eq!(
            keys,
            vec![
                "ts",
                "session_id",
                "prompt_id",
                "event",
                "classification",
                "skill_fired",
                "escaped",
                "blocked",
                "outcome",
                "reason",
            ]
        );
    }

    /// Python wrote microsecond precision with a `+00:00` offset.
    #[test]
    fn timestamp_precision_matches_python_isoformat() {
        let ts = now_iso();
        assert!(ts.ends_with("+00:00"), "expected a +00:00 offset: {ts}");
        let frac = ts.split('.').nth(1).expect("fractional seconds");
        assert_eq!(frac.trim_end_matches("+00:00").len(), 6, "microseconds: {ts}");
    }

    #[test]
    fn a_passing_turn_logs_exactly_one_record() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", Some("locus-algorithm"));
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nOBSERVE", false));
        let r = records(&c);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0]["event"], "turn");
        assert_eq!(r[0]["outcome"], "passed");
    }

    #[test]
    fn an_escaped_turn_records_the_escape() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("just do it, locus: skip", None);
        verify(&stop_event(&c, "no classification", false));
        let r = records(&c);
        assert_eq!(r[0]["outcome"], "escaped");
        assert_eq!(r[0]["escaped"], true);
    }

    #[test]
    fn blocked_then_recovered_logs_turn_then_recovery() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nx", false));

        // The retry invokes the skill.
        let c2 = Case {
            _dir: c._dir,
            log: c.log.clone(),
            transcript: c.transcript.clone(),
        };
        let rows = format!(
            "{}\n{}",
            std::fs::read_to_string(&c2.transcript).unwrap(),
            serde_json::json!({"type":"assistant","message":{"role":"assistant",
                "content":[{"type":"tool_use","name":"Skill","input":{"skill":"locus-algorithm"}}]}})
        );
        std::fs::write(&c2.transcript, rows).unwrap();

        verify(&stop_event(&c2, "**Classification: Non-trivial**\n\nOBSERVE", true));

        let r = records(&c2);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0]["outcome"], "blocked");
        assert_eq!(r[1]["event"], "recovery");
        assert_eq!(r[1]["outcome"], "recovered");
        assert_eq!(r[0]["prompt_id"], r[1]["prompt_id"]);
    }

    #[test]
    fn blocked_then_not_recovered_logs_unrecovered() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nx", false));
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nstill nothing", true));
        let r = records(&c);
        assert_eq!(r.len(), 2);
        assert_eq!(r[1]["outcome"], "unrecovered");
    }

    /// `stop_hook_active` says some Stop hook blocked, not that ours did.
    /// Without the marker we would invent recovery data for a turn we never
    /// touched, in the one file whose whole value is being trustworthy.
    #[test]
    fn no_recovery_record_when_the_block_was_not_ours() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        verify(&stop_event(&c, "someone else blocked this", true));
        assert!(records(&c).is_empty());
    }

    #[test]
    fn the_marker_is_consumed_not_left_behind() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nx", false));
        assert!(c.log.join("pending").join("P1.marker").exists());
        verify(&stop_event(&c, "**Classification: Non-trivial**\n\ny", true));
        assert!(!c.log.join("pending").join("P1.marker").exists());
    }

    /// A blocked turn aborted before its recovery Stop leaves its marker
    /// behind. Harmless but unbounded, so writes sweep the old ones.
    #[test]
    fn stale_markers_are_pruned_on_the_next_block() {
        let _g = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let c = case("refactor the auth module", None);
        let pending = c.log.join("pending");
        std::fs::create_dir_all(&pending).unwrap();

        let stale = pending.join("ancient.marker");
        let fresh = pending.join("recent.marker");
        std::fs::write(&stale, b"").unwrap();
        std::fs::write(&fresh, b"").unwrap();

        // Age the stale one past the TTL.
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(7200);
        std::fs::File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_modified(old)
            .unwrap();

        verify(&stop_event(&c, "**Classification: Non-trivial**\n\nx", false));

        assert!(!stale.exists(), "a marker past the TTL should be pruned");
        assert!(fresh.exists(), "a fresh marker must survive the sweep");
    }
}
