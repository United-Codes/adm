# ADM AI Chat Demo: ask questions across your documents

The database side of the course "Ask questions across your documents". It builds, on invented
sample files:

- two ADM users with different access (`AIC_LEGAL`, `AIC_HR`), two groups, ten small PDFs
- two RAG collections (`aic_contracts`, `aic_policies`) on the native Oracle vector store
- a PL/SQL tool package, a prompt profile and an agent that answer from both collections
- scripts that show each step and measure what it costs

The APEX chat page (phase 2) is not part of this folder yet.

Everything this demo creates has the prefix `aic_` (or `AIC_`). `db/99_aic_teardown.sql` removes all
of it.

## Prerequisites

- Oracle Database 23ai or later (native vector store)
- ADM with the AI Pack installed (`install.sql`, then `install_ai.sql`)
- An APEX web credential with the static id `OPENAI` in the workspace of the ADM schema
- SQLcl, connected as the ADM schema owner. The commands below use the saved connection
  `local-23ai-adm`.

Costs: the whole install embeds about 2,000 tokens and reads one scanned page with a model. An agent
run uses 1,000 to 4,000 tokens. The bundled agent in `16_aic_bundled_tools.sql` uses about 16,000.

## Run it

```bash
make precheck            # six checks, each with the fix for a failure
make install             # steps 1 to 7, about 30 seconds
make lesson-05           # then the lesson scripts, one at a time
make teardown            # remove everything
```

Without make: `cd db; sql -name local-23ai-adm @install.sql`. Each lesson script that runs an agent
must start in a **fresh** SQLcl session, because the first `execute_agent` of a database session
behaves differently (see lesson 2, `09_aic_identity_wipe.sql`).

## What is in `db/`

| File | What it does | Lesson |
| --- | --- | --- |
| `00_precheck.sql` | Checks 23ai, the AI Pack, the web credential, the embedding and answer model | 1 |
| `01_aic_users.sql` | Users `AIC_LEGAL`, `AIC_HR` (role CONTRIBUTOR, not administrators) and their groups | 1 |
| `02_aic_load_pdfs.sql` | Generated. Loads the 10 PDFs with `p_run_hooks => false` and shares some across groups | 1 |
| `03_aic_collections.sql` | Creates the two collections with the smallest configuration that works | 1 |
| `04_aic_index.sql` | Text index, user caches, chunking and embedding, with the cost printed | 1 |
| `05_aic_lesson1_answers.sql` | `generate_answer` and the follow-up it cannot answer | 1 |
| `06_aic_rag_tools_api.pks/.pkb` | The tool functions: JSON in, JSON out, never raise, four statuses | 2 |
| `07_aic_agent_api.pks/.pkb` | `run_as`: runs an agent as an ADM user from plain SQL (an exception, see below) | 2 |
| `08_aic_register.sql` | Registers one tool, the prompt profile and the agent | 2 |
| `09_aic_identity_wipe.sql` | Shows that the first `execute_agent` call removes the ADM user | 2 |
| `10_aic_first_run.sql` | The first agent run with the fix, and its trace | 2 |
| `11_aic_second_tool.sql` | The follow-up with one tool, then with two | 3 |
| `12_aic_two_users.sql` | Two users: direct tool calls, `p_limit`, agent runs | 5 |
| `13_aic_trace.sql` | Reads `uc_ai_agent_executions` and `uc_ai_agent_messages` | 6 |
| `14_aic_questions.sql` | 10 questions with the expected document, and the retrieval sweep (threshold, hybrid) | 6 |
| `15_aic_agent_questions.sql` | The same questions through the agent, with tokens | 6 |
| `16_aic_bundled_tools.sql` | The bundled tools on the same documents | 6 |
| `17_aic_export_chunks.sql` | Exports the chunks so that `samples/count_tokens.py` can count embedding tokens | 6 |
| `99_aic_teardown.sql` | Removes everything, with a verification select | |

`samples/` holds the PDF generator (`generate_samples.py`, needs reportlab, poppler and ImageMagick),
the generator of `02_aic_load_pdfs.sql`, `manifest.csv` (who may see which file) and the PDFs.

## Who sees what

| File | AIC_LEGAL | AIC_HR |
| --- | --- | --- |
| 4 text contracts + 1 scanned amendment | all but Helios: 5 | 4 (not the Helios contract) |
| 5 policies | 4 (not the salary bands) | 5 |

The contracts live in `/groups/aic_legal`, the policies in `/groups/aic_hr`. Group members see
their group folder. Files marked in `manifest.csv` are also shared with the other group, one
document share each.

## Running an agent from SQL is an exception

`aic_agent_api.run_as(user, agent, question)` takes a user name and trusts it. It exists only so
that a script can run an agent as a user. Do not use it in an application.

- In a product, an agent runs inside an existing APEX session of a signed-in user, or from the chat
  plug-in. The plug-in runs the agent in a job. Its Session Init Code calls `apex_session.attach`
  and then `adm_context_api.establish_from_session`.
- The first `uc_ai_agents_api.execute_agent` call in a database session creates an APEX session
  of its own. The initialization code of that application clears the ADM context. So the user that
  you set before the call is gone, and the tools see nobody. `run_as` creates the APEX session
  first, then sets the ADM context, then runs the agent.

## Phase 2: the chat page

Not built yet. It needs:

- The same user names as APEX accounts in the workspace that runs the page (`AIC_LEGAL`, `AIC_HR`),
  because the page logs the user in.
- A standalone APEX application with the `ucAiChat` plug-in. The plug-in is not vendored in this
  repository. See `scripts/deps/deps.conf` and `src/apex/adm/pages/p00071-fs-ai-chat.apx` for how
  the product does it.
- Application initialization with `adm_context_api.establish_from_session`, and Session Init Code
  with `apex_session.attach` followed by `adm_context_api.establish_from_session`.
- The agent code `aic_assistant` as the agent of the plug-in.

The measurements and problems found so far are in `NOTES.md`.
