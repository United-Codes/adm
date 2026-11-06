# ADM AI Chat Demo: ask questions across your documents

The database side of the course "Ask questions across your documents". It builds, on invented
sample files:

- two ADM users with different access (`AIC_LEGAL`, `AIC_HR`), two groups, ten small PDFs
- two RAG collections (`aic_contracts`, `aic_policies`) on the native Oracle vector store. The install
  creates `aic_contracts`; lesson 1 creates `aic_policies` in the RAG collection manager, or
  `db/03b_aic_policies.sql` creates it in SQL
- a PL/SQL tool package, a prompt profile and an agent that answer from both collections
- scripts that show each step and measure what it costs. Lesson 6 creates a third collection,
  `aic_policies_large`, in the RAG collection manager to compare a chunk size
- lesson 7: a search bridge in the ADM schema, the ADM user `AIC_SERVICE`, and an agent in a SECOND
  schema (`AIC_APP`) that searches the collections through the bridge

- `chat-app/`: the APEX application with the chat page (application 218), and the scripts that create its two accounts

Everything this demo creates has the prefix `aic_` (or `AIC_`). `db/99_aic_teardown.sql` removes all
of it in the ADM schema. Lesson 7 also creates objects in the application schema
(`db/98_aic_app_teardown.sql` removes them) and, optionally, the demo schema `AIC_APP` itself
(`db/97_aic_app_schema_drop.sql`, run by a DBA).

## Prerequisites

- Oracle Database 23ai or later (native vector store)
- ADM with the AI Pack installed (`install.sql`, then `install_ai.sql`)
- An APEX web credential with the static id `OPENAI` in the workspace of the ADM schema
- SQLcl, connected as the ADM schema owner. The commands below use the saved connection
  `local-23ai-adm`.
- Lesson 7 only: a second schema with UC AI and an APEX application, in the APEX workspace of the
  ADM schema. Or a DBA connection, to create the demo schema `AIC_APP` with
  `db/22_aic_app_schema.sql` (demo password, local database only)

Costs: the whole install embeds about 2,000 tokens and reads one scanned page with a model. An agent
run uses 1,000 to 4,000 tokens. The bundled agent in `16_aic_bundled_tools.sql` uses about 20,000.
`20_aic_config_matrix.sql` makes 30 agent runs (about 45,000 to 50,000 input tokens); with the argument `search`
it makes none. Lesson 7 makes one agent run in the second schema (about 3,300 input tokens) and about 15
search embeddings.

## Run it

```bash
make precheck            # six checks, each with the fix for a failure
make install             # steps 1 to 7, about 30 seconds
make policies            # aic_policies in SQL, if you do not create it in the RAG collection manager
make lesson-05           # then the lesson scripts, one at a time
make teardown            # remove everything
```

Lesson 7 runs in a second schema. The defaults use the demo schema `AIC_APP` and the demo password of
`db/22_aic_app_schema.sql`. Set `APP_CONN` for a schema of your own:

```bash
make app-schema                                    # as a DBA (DBA_CONN): create AIC_APP
make app-uc-ai UC_AI_INSTALL=<path>/install_uc_ai_complete.sql
make lesson-24                                     # ADM schema: AIC_SERVICE, the bridge, the grant
make lesson-25                                     # ADM schema: check the bridge without a model
make app-lesson-27                                 # AIC_APP: tools, profile, agent
make app-lesson-28                                 # AIC_APP: one agent run and its trace
make app-teardown                                  # AIC_APP objects, then drop AIC_APP (DBA)
```

Without make: `cd db; sql -name local-23ai-adm @install.sql`. Only `09_aic_identity_wipe.sql` needs a
**fresh** SQLcl session, because the first `execute_agent` of a database session behaves differently
(see lesson 2). The other scripts run the agent through `aic_agent_api.run_as`, which creates the
APEX session itself, so they work in any session.

## What is in `db/`

| File | What it does | Lesson |
| --- | --- | --- |
| `00_precheck.sql` | Checks 23ai, the AI Pack, the web credential, the embedding and answer model | 1 |
| `01_aic_users.sql` | Users `AIC_LEGAL`, `AIC_HR` (role CONTRIBUTOR, not administrators) and their groups | 1 |
| `02_aic_load_pdfs.sql` | Generated. Loads the 10 PDFs with `p_run_hooks => false` and shares some across groups | 1 |
| `03_aic_collections.sql` | Creates the collection `aic_contracts` with the smallest configuration that works | 1 |
| `03b_aic_policies.sql` | Not part of the install. Creates and indexes `aic_policies` with the configuration the RAG collection manager builds | 1 |
| `04_aic_index.sql` | Text index, user caches, chunking and embedding of `aic_contracts`, with the cost printed | 1 |
| `05_aic_lesson1_answers.sql` | `generate_answer` and the follow-up it cannot answer | 1 |
| `06_aic_rag_tools_api.pks/.pkb` | The tool functions: JSON in, JSON out, never raise, four statuses | 2 |
| `07_aic_agent_api.pks/.pkb` | `run_as`: runs an agent as an ADM user from plain SQL (an exception, see below) | 2 |
| `08_aic_register.sql` | Registers one tool, the prompt profile and the agent | 2 |
| `09_aic_identity_wipe.sql` | Shows that the first `execute_agent` call removes the ADM user | 2 |
| `10_aic_first_run.sql` | The first agent run with the fix, and its trace | 2 |
| `11_aic_second_tool.sql` | The follow-up with one tool, then with two | 3 |
| `12_aic_two_users.sql` | Two users: direct tool calls, `p_limit`, agent runs | 5 |
| `13_aic_trace.sql` | Reads `uc_ai_agent_executions` and `uc_ai_agent_messages` | 5 |
| `14_aic_questions.sql` | 10 questions with the expected document, and the retrieval sweep (threshold, hybrid) | 6 |
| `14b_aic_admin_sees_policies.sql` | Adds an ADM administrator (argument) to the group `AIC_HR`, so that the test console of the RAG collection manager finds the policies | 6 |
| `15_aic_agent_questions.sql` | The same questions through the agent, with tokens | 6 |
| `16_aic_bundled_tools.sql` | Optional, not part of a lesson. The bundled tools of the AI Pack on the same documents | |
| `17_aic_export_chunks.sql` | Optional, not part of a lesson. Exports the chunks so that `samples/count_tokens.py` can count embedding tokens | |
| `18_aic_apex_users.sql` | The APEX accounts `AIC_LEGAL` and `AIC_HR` for the chat page (demo password, local schema only) | 4 |
| `19_aic_chat_verify.sql` | Who each chat run ran as, and who the search tool searched as | 4 |
| `20_aic_config_matrix.sql` | One search per question under seven search settings, the chunk size compared with `aic_policies_large`, and the question list through the agent three times (stored settings, no surrounding chunks, query rewriting). `@20_aic_config_matrix.sql search` skips the agent runs | 6 |
| `21_aic_tools_without_max_sources.sql` | Registers both search tools again with only the parameter `query`, so that the stored `default_max_sources` of the collection reaches the agent | 6 |
| `22_aic_app_schema.sql` | **As a DBA, optional.** Creates the demo application schema `AIC_APP` (demo password) and adds it to the APEX workspace of the ADM schema | 7 |
| `22b_aic_app_application.sql` | **As `AIC_APP`, optional.** Creates an empty APEX application for `AIC_APP`, because UC AI runs tool code in the parsing schema of the application of the session | 7 |
| `23_aic_rag_bridge_api.pks/.pkb` | The bridge: searches one `aic_*` collection as the fixed ADM user `AIC_SERVICE` (`search_passages`) or as a named non-admin user of an allowed group (`search_passages_for_user`), gives the caller its ADM user back on every path, then pipes the rows | 7 |
| `24_aic_bridge_setup.sql` | Creates `AIC_SERVICE` (VIEWER, group `AIC_LEGAL`), installs the bridge, grants `execute` on it (and nothing else) to `AIC_APP` | 7 |
| `25_aic_bridge_check.sql` | Calls `prepare_sources` without an ADM user, and the bridge as `AIC_HR`: refusal, unknown name, an error inside the search, a caller that stops after one row, the per-user function | 7 |
| `26_aic_app_tools_api.pks/.pkb` | **In `AIC_APP`.** The two search tools, calling the bridge through a synonym, and two per-user variants that pass the signed-in APEX user | 7 |
| `27_aic_app_register.sql` | **As `AIC_APP`.** Synonym, tool package, two tools, prompt profile and agent | 7 |
| `28_aic_app_run.sql` | **As `AIC_APP`.** The tools by hand, then one agent run in an APEX session of the `AIC_APP` application, and its trace | 7 |
| `29_aic_app_per_user.sql` | **As `AIC_APP`.** The per-user search as `AIC_LEGAL`, `AIC_HR`, an administrator and an unknown name (no model) | 7 |
| `97_aic_app_schema_drop.sql` | **As a DBA.** Removes `AIC_APP` from the workspace and drops it | 7 |
| `98_aic_app_teardown.sql` | **As `AIC_APP`.** Removes what lesson 7 created in the application schema, including the application of `22b` | 7 |
| `99_aic_teardown.sql` | Removes everything in the ADM schema, including the APEX accounts, the bridge and `AIC_SERVICE`, with a verification select | |

`samples/` holds the PDF generator (`generate_samples.py`, needs reportlab, poppler and ImageMagick),
the generator of `02_aic_load_pdfs.sql`, `manifest.csv` (who may see which file) and the PDFs.

## Who sees what

| File | AIC_LEGAL | AIC_HR |
| --- | --- | --- |
| 4 text contracts + 1 scanned amendment | all 5 | 4 (not the Helios contract) |
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

## The chat page

Lesson 4 adds a standalone APEX application, `chat-app/`, with the `ucAiChat` region plug-in:

```bash
make apex-users          # APEX accounts AIC_LEGAL and AIC_HR, demo password Aic-Demo-2026
make app-import          # imports application 218 into the workspace of the connection
```

Open `https://<your ORDS host>/ords/r/<workspace>/aic-chat/` and sign in as `AIC_LEGAL` or `AIC_HR`. The demo password is
written in `db/18_aic_apex_users.sql`: use these accounts on a local schema only. `make teardown` removes them.
The app needs APEX 26.1 or later and a SQLcl release that supports `apex import` for APEXlang. The plug-in is the same one
that the ADM file browser uses (MIT licence).
`db/19_aic_chat_verify.sql` shows, for every run of the chat page, which user ran it and which user the search tool searched as.

The measurements and problems found so far are in `NOTES.md`.
