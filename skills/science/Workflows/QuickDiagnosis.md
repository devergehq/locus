# Quick Diagnosis Workflow

**The 15-minute rule** — if a debugging problem hasn't yielded to ad-hoc investigation in 15 minutes, switch to structured diagnosis. Quick Diagnosis is a compressed Science cycle for fast debugging.

## Execution

### 1. State the symptom (30 seconds)
One sentence. "Login fails with a 500 error for users created in the last hour."

### 2. State the goal (30 seconds)
What would count as resolution. "Login succeeds for all users, old and new, within 5 minutes of investigation."

### 3. Three hypotheses (3 minutes)
Generate three — never stop at one. Write them down. For each, predict the distinguishing observation.

Example:
1. **Race condition** — new user's profile not yet replicated to read replica. Distinguishing: error only for users created within replication-lag window.
2. **Missing role assignment** — new users lack the default role. Distinguishing: error in authorisation layer, not authentication.
3. **Schema migration drift** — recent migration added a required column the login path doesn't populate. Distinguishing: error in insert, not query.

### 4. Cheapest distinguishing experiment (2 minutes)
Which observation distinguishes the hypotheses with the least effort?

Reproduce the bug once with full logging. The error path tells you which layer failed — authentication, authorisation, or data — and that rules out 2 of the 3 hypotheses.

### 5. Run it (5 minutes)
Do the experiment. Collect the evidence.

### 6. Verdict (2 minutes)
Which hypothesis is supported by the evidence? If none are clearly supported, the hypotheses were wrong — generate three new ones informed by what you just saw.

### 7. Fix and verify (remaining budget)
Apply the fix implied by the supported hypothesis. Verify the symptom is gone. If not, the supposedly-supported hypothesis was wrong too.

## Total budget: ~15 minutes

If the diagnosis takes longer:

- The problem is not diagnosable with the available evidence — add instrumentation first.
- The problem is multi-cause — split into distinct problems.
- The hypothesis generation is shallow — ask a colleague or Council.

## Anti-patterns

- **Skipping hypothesis generation.** "Let me just poke around" — almost always slower.
- **Testing one hypothesis at a time with expensive tests.** Find the cheap distinguishing test.
- **Believing the first hypothesis before the evidence arrives.** Confirmation bias wastes more debug time than any other failure.
- **Giving up at 14 minutes.** The protocol only works if you follow it all the way through.
