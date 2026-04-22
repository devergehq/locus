# Science Protocol

How other Locus skills implement the Science cycle. Science is the meta-skill; other skills are domain-specific applications of it.

## The protocol

Every skill that claims to produce rigorous output should:

1. **State the goal explicitly** — what counts as success for this skill invocation.
2. **Observe baseline** — what is the current state / existing solution / status quo.
3. **Generate multiple hypotheses** — at least three credible options.
4. **Design a test** — even if the test is "run Council on the options".
5. **Measure** — collect the data or run the test.
6. **Analyze honestly** — against the stated goal.
7. **Iterate** — refine if the result is underdetermined or the goal has shifted.

## Per-skill mappings

### Council → Science

| Science phase  | Council mapping                                         |
|----------------|---------------------------------------------------------|
| Goal           | The question being debated (success criterion stated)   |
| Observe        | Round 1 initial positions (current thinking surfaced)   |
| Hypothesize    | Round 1 positions (multiple candidate answers)          |
| Experiment     | Rounds 2-3 (test hypotheses against each other)         |
| Measure        | Which arguments survived rebuttal                       |
| Analyze        | Synthesis — weighing arguments by quality not volume    |
| Iterate        | If synthesis is weak, run another round or escalate     |

### Red Team → Science

| Science phase  | Red Team mapping                                        |
|----------------|---------------------------------------------------------|
| Goal           | Find the load-bearing flaw if one exists                |
| Observe        | Decomposition into atomic claims                        |
| Hypothesize    | Each attacker's proposed flaw                           |
| Experiment     | Parallel attack from trait-diverse perspectives         |
| Measure        | Which flaws converged across attackers                  |
| Analyze        | Rank by convergence and depth                           |
| Iterate        | If no load-bearing flaw surfaced, proposal may be sound |

### Research → Science

| Science phase  | Research mapping                                        |
|----------------|---------------------------------------------------------|
| Goal           | The research question                                   |
| Observe        | Existing knowledge / prior literature                   |
| Hypothesize    | The research question reframed as testable claims       |
| Experiment     | The searches performed                                  |
| Measure        | Evidence gathered                                       |
| Analyze        | Synthesis of findings with confidence markers           |
| Iterate        | Follow-up searches based on gaps                        |

### Iterative Depth → Science

| Science phase  | IterativeDepth mapping                                  |
|----------------|---------------------------------------------------------|
| Goal           | Surface hidden requirements missed by single-pass       |
| Observe        | The initial requirement statement                       |
| Hypothesize    | Each lens is a testable perspective                     |
| Experiment     | Apply each lens to the problem                          |
| Measure        | Criteria surfaced per lens; convergence across lenses   |
| Analyze        | Consolidated criteria with convergence signal           |
| Iterate        | If lens pass was shallow, deepen or add lenses          |

### First Principles → Science

| Science phase  | First Principles mapping                                |
|----------------|---------------------------------------------------------|
| Goal           | Find the foundational truths of the claim               |
| Observe        | Surface every assumption                                |
| Hypothesize    | For each assumption: is it true / necessary / valid?    |
| Experiment     | Challenge each assumption directly                      |
| Measure        | Categorise — axiom / legacy / unverified / false        |
| Analyze        | Reconstruct from axioms only                            |
| Iterate        | If reconstruction differs from original, re-examine     |

## When the protocol breaks

Not every task is a scientific experiment. Short, uncontroversial tasks (rename a variable, format a file) do not benefit from Goal/Observe/Hypothesize discipline.

The protocol kicks in when:

- The outcome is uncertain and matters.
- Multiple credible paths exist.
- The cost of a wrong answer is high.
- The existing understanding of the problem may be incomplete.

Under those conditions, every skill should implement this protocol.
