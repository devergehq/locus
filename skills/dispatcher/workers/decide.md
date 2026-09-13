# Mode: decide

Finish line: **every question on the ticket has a recorded answer, or is explicitly escalated
to a named person.** No code, no commits, no PR, no branch.

This mode exists because a decision ticket forced through `implement.md` gets a session whose
finish line is a PR it must not create, and forced through `investigate.md` gets a session
whose finish line is *posting findings* — which it can reach with half the questions
unanswered. Here the questions are the unit of work.

## Steps

1. **Enumerate the questions.** Read the whole ticket and every comment. The questions are
   usually the acceptance criteria; where they are prose, restate them as a numbered list in
   your first comment so there is something to check off.

2. **Sort each question into one of two kinds. This is the whole job.**

   - **Checkable** — the answer exists in a system somebody can read: a config value, a query,
     a task definition, a log, the code. **You answer these.** Run the command, post the
     output, and say what you ran.
   - **Held by a person** — the answer is a preference, a policy, a business rule, or a fact
     only a human holds. **You never answer these**, and you never infer them from what the
     code happens to do. Ask, in one comment, naming who you think holds the answer.

   **A refusal is not an absence, and the difference decides who owns the question.** Before
   you treat anything as held by a person, establish which of three things is true: the tool is
   in your toolset (answer it); the tool exists on this machine but your session was refused
   (a **permission defect** — report the denial and ask for the rule, and leave the question
   classified as cheap); or no such capability exists anywhere (escalate). Where your instance
   names a read-only production MCP under `tools.production_mcp`, a classifier refusing it is
   the second case, not the third. "I could not read production" is not an answer until you have said which one it was —
   and a guess dressed as a finding is never one.

3. **Answer the checkable ones first**, and post each answer as you get it rather than
   batching. A later question often turns on an earlier answer, and a half-answered ticket
   that shows its working is more useful to the next person than a silent one.

   Read-only, always. Production data only when the question needs it, and only ids and
   aggregates in anything you post.

4. **Ask the rest in one comment**, on the ticket the acceptance criteria name. Read them
   carefully: they usually say where each answer is to be recorded, and it is often the
   **parent** rather than your own ticket. If they say nothing, use your own ticket — a
   coordinator-dispatched child has a parent to fall back to and a poller-raised one does not,
   so "the parent" is not always a referent. One comment, one question per line, each with
   what turns on the answer and who you think can give it.

   **Commenting on any ticket that is not your own, pass `--key <YOUR KEY>`:**
   `D comment <PARENT> --key <YOUR KEY> --mode decide`. Without it `D comment` resolves the
   mode from the *parent's* ledger entry and signs `agent:<PARENT>/implement` — and a watcher
   skips comments bearing its own ticket's marker, so your coordinator's watch on the parent
   would drop the very answers it is waiting for. With it the signature is
   `agent:<YOUR KEY>/decide`, which is both true and visible to it.

   `D label <KEY> needs-input`, `D ledger put <KEY> status=needs-input`, message whoever
   dispatched you. Then **keep working on everything the missing answers do not block.**

5. **When an answer arrives** as a comment, record it in the same place as the others,
   restore your working label, and carry on.

6. **Close only when the list from step 1 is complete.** Every question either has a recorded
   answer or has a named person it is waiting on, and your closing comment says which is which.
   `D label <KEY> done` → `D ledger put <KEY> status=done` → message whoever dispatched you.

   If questions are still outstanding, you are not done. `needs-input` is the honest status and
   it is not a failure — a decision ticket that closes with unanswered questions unblocks work
   that should have stayed blocked.

## Never

- Answer a business question because the answer seems obvious from the code. What the code does
  today and what the business wants are different facts, and this mode exists to keep them apart.
- Change the ticket's scope, or any other ticket's, because of an answer you got. Report what
  changed and let whoever dispatched you decide.
- Write code, open a branch, or open a PR. If the answers make a code change obviously correct,
  say so in your closing comment and stop.
