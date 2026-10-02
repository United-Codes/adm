# ADM Hooks Demo

A sample APEX app (id **217**, APEXlang source in [hooks-demo/](hooks-demo/)) plus the database objects behind it
that shows how to build **custom workflows on ADM hooks**. Not part of the ADM product: everything is prefixed
`hkd_` and lives next to ADM in the same schema.

## The pattern

ADM allows one snippet per event, runs it **inside the caller's transaction**, and aborts the operation if it raises.
That is perfect for a rule and wrong for anything slow or fallible. So the hook here only does two things:

1. a cheap **synchronous guard** that may refuse the operation
2. an **enqueue** of one Advanced Queuing message

A worker then picks the message up **in its own transaction**:

```
 upload / new folder ──► ADM hook (sync) ──► AQ queue ──► worker (async) ──► tags, folders, log, outbox
   caller's transaction   guard + enqueue     visible on     own transaction,   ADM API calls as
                                              commit         retries, DLQ       system / the actor
```

Why a queue rather than a plain table:

- the enqueue is part of the uploader's transaction: roll the upload back and the message goes with it
- dequeue locks the message, so several workers can run side by side
- retry count, retry delay and an exception queue are built in (`max_retries 3`, `retry_delay 5s`)

## The five examples

| Example | Runs | On | What it shows |
| --- | --- | --- | --- |
| **Upload guard** | sync, in the hook | `AFTER_NEW_FILE_UPLOAD`, `AFTER_NEW_FILE_VERSION` | Refusing an operation: blocked extensions (`hkd_blocked_extensions`) and empty files. Logs the reason in an *autonomous* transaction, because the raise rolls the upload back. |
| **Intake classification** | async | `AFTER_NEW_FILE_UPLOAD` | Classifies by name and type, writes `category` / `needs-review` **tags into ADM** through `adm_tag_api`. |
| **Duplicate scan** | async | `AFTER_NEW_FILE_UPLOAD` | Compares `adm_document_versions.checksum` (no file read), tags `duplicate-of`, flags large files. |
| **Version digest** | async | `AFTER_NEW_FILE_VERSION` | Compares with the previous version, flags a version that shrank by more than half, writes an outbox notification. |
| **Project folder blueprint** | async | `AFTER_NEW_FOLDER_CREATION` | A folder created in a folder named `Projects` gets `01_Contracts`, `02_Deliverables`, `03_Archive`, created *as the user*. Shows the **recursion guard** a workflow needs when it creates what fires its own hook. |

Failure demo: a file with `poison` in its name makes the classification workflow raise. Watch the queue retry three
times, then park the message in the exception queue. **Requeue** it from the Queue & Outbox page.

## Reading the code in the app

Every page opens with a short explanation of what it shows, and the menu entry **How It Works: The Code** walks one
upload through the whole chain: the snippet ADM runs, the guard, the enqueue, the worker loop and each workflow, with an
explanation above each piece. The code is read live from `adm_hooks` and `user_source` (`hkd_demo_api.render_source`),
so the page cannot drift from the code that runs.

## Install

Needs ADM installed in the schema, and an APEX workspace over that schema.

```bash
cd examples/hooks-demo-app
make db-grants     # once, as a DBA: execute on dbms_aq / dbms_aqadm for the ADM schema
make db-install    # tables, queue, packages, registers the three hooks + AQ notification + job
make app-import    # APEX app 217
```

Targets default to the SQLcl connections `local-23ai-adm` and `local-23ai-sys`; override with
`make db-install DB_CONN=...`. If your SQLcl binary is not called `sql`, pass `SQL=sqlcl`. `make` lists everything.

`make app-export` writes the app back to [hooks-demo/](hooks-demo/) after you changed it in App Builder.

Sign in with an APEX account that **also has an active ADM account** (the app refuses everyone else). Create both accounts before you sign in. See the
[ADM user documentation](https://united-codes.com/products/apex-document-management/docs/admin/users-and-groups/).

`make db-install` refuses to overwrite a hook somebody else registered. `make db-uninstall` gives the slots back
(documents, tags and folders the workflows created stay: they are ordinary ADM data).

## The tutorial

`tutorial/` holds the scripts of the docs tutorial "Build workflows on hooks": `00_setup.sql` to `06_blueprint.sql`, one or
two for each lesson, and `99_teardown.sql`. Each script builds on the one before it, with the same object names as the demo, and
`06_blueprint.sql` extends the tutorial with the folder hook and standard project layout. To add the complete demo,
including the version digest, outbox, and APEX support package, run `make db-install` separately.
The staged scripts for lessons 2 to 6 are generated from
`db/04_hkd_worker_api.pkb` by taking features away, so change the demo package first and regenerate. Run the scripts from the
`tutorial/` directory.

## Files

| File | Purpose |
| --- | --- |
| `db/00_dba_grants.sql` | AQ privileges, run once by a DBA |
| `db/01_hkd_tables.sql` | workflow registry, blocked extensions, run log, refusals, outbox |
| `db/02_hkd_queue.sql` | payload type, queue table, queue (retries, exception queue) |
| `db/03_hkd_hook_api.*` | **the hooks**: guard + enqueue |
| `db/04_hkd_worker_api.*` | **the worker**: dequeue loop, the four workflows, AQ notification callback, requeue |
| `db/05_hkd_demo_api.*` | glue for the APEX pages |
| `db/06_hkd_register_hooks.sql` | registers hooks in `adm_hooks`, the AQ notification and the sweeper job |
| `db/99_hkd_uninstall.sql` | removes everything |

## How the worker gets woken

Two ways, both call `hkd_worker_api.process_queue`:

- an **AQ notification** (`dbms_aq.register`): Oracle calls `on_message` in a job session when the uploader commits, so
  results appear within a second or two
- a **scheduler job** every 30 s: a message waiting out its retry delay produces no notification, so something has to look

Both are safe at the same time because dequeue locks the message.

## Things that bit while building this

- The user sees what a hook raises only when the error number is in `-20700 .. -20999`. ADM does not wrap those, and
  `adm_error.apex_error_handler` shows the message. Any other error from a hook is wrapped as "There was an error processing
  the after_new_file_upload". The guard raises `-20701` and `-20702`, so the user reads the real reason. It also logs the
  refusal in `hkd_rejections` (autonomously), because a refused upload leaves nothing else behind.
- ADM ignores an upload whose content equals the latest version: no new version, **no hook fires**.
- Oracle creates the exception queue closed for dequeue; `02_hkd_queue.sql` opens it.
- `create or replace type` fails with ORA-02303 once a queue table uses it, so the type is created only when missing.
- Customer errors use `-20700 .. -20999`; the demo uses `-20701`, `-20702`, `-20711`, `-20720`.
