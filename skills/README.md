# ADM agent skills

Skills that teach an AI coding agent how to write correct PL/SQL against **APEX Document
Management (ADM) 26.1**. Drop them into a project and your agent stops guessing at ADM's API:
it knows that a session needs a context first, that no ADM package commits, that file content
is read through `adm_storage_api.get_file_content` rather than off a BLOB column, and which
signatures are real.

They cover the **public** API only — nothing marked `@private`, which is what stops your code
depending on plumbing that changes between releases.

## Install

Per project — the skills apply to everyone who works in that repository:

```sh
mkdir -p <your-project>/.claude/skills
cp -R adm-* <your-project>/.claude/skills/
```

Or for every project you work on:

```sh
cp -R adm-* ~/.claude/skills/
```

Then start a new session. The agent loads a skill when the task matches its description; you can
also ask for one by name ("use the adm-documents skill"). Each skill is a single self-contained
`SKILL.md`, so any agent that reads that format can use them — the format is not Claude-specific.

## What is here

| Skill | Covers |
| --- | --- |
| `adm-plsql` | **Read this one first.** Establishing a security context, who owns the transaction, catching ADM errors, and what keeps your code upgradeable. |
| `adm-documents` | Uploading, versioning, reading content back, mime types, retention, legal hold, comments, annotations. |
| `adm-folders` | Paths and ids, building nested structures, renaming, moving, and how the trash treats a subtree. |
| `adm-querying` | The session-scoped `adm_my_*_v` views, the unfiltered `adm_report_*_v` views, the core tables, restricting a query to what one user may see, and joining ADM ids to your own tables. |
| `adm-search-and-tags` | Tags and tag values, full-text search, and faceted search. |
| `adm-sharing-and-permissions` | Permission checks, shares, public link shares, embed tokens, users and groups. |
| `adm-hooks` | The three hook events, and how raising in a hook refuses an upload. |
| `adm-zip` | Packing and expanding archives, the size guards, and the rollback they need. |
| `adm-ai-rag` | AI Pack only: RAG collections, chunk search, and generated answers. |

## Keeping in step

These describe ADM **26.1**. The authoritative reference is generated from the installed package
specs and is always in step with your database:

- API reference — <https://united-codes.com/products/apex-document-management/docs/api/>
- Developer guides — <https://united-codes.com/products/apex-document-management/docs/dev/extensibility/>

If a skill and the reference disagree, the reference is right — and tell us, because the skill is
wrong and we would like to fix it.
