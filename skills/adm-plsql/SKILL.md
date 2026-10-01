---
name: adm-plsql
description: >
  The rules for calling APEX Document Management (ADM) from your own PL/SQL: establishing a
  security context, who owns the transaction, catching ADM errors, and what is supported
  versus what breaks on the next upgrade. Read this before writing any code that calls an
  adm_ package. Use whenever a task mentions ADM, document management, or names anything
  matching adm_%_api, adm_context_api, adm_error, adm_documents or adm_folders - and use it
  together with the more specific adm-documents, adm-folders, adm-querying,
  adm-search-and-tags, adm-sharing-and-permissions, adm-hooks, adm-zip and adm-ai-rag skills.
---

# Calling ADM from your own PL/SQL

ADM (APEX Document Management) runs **inside your Oracle database**. Every object is prefixed
`adm_`, there is no integration layer and no API key: you call PL/SQL packages in your own
schema, or in a schema you have been granted on.

Four rules decide whether your code works at all. They are not style preferences.

## 1. Establish a context first, or nothing is permitted

ADM authorizes against a **session context** (Oracle application context namespace
`ADM_CONTEXT`), not against database roles. It holds the current username, their role
(`ADMIN` / `EDIT` / `VIEW`) and the access source (`DB` / `APEX` / `REST` / `EMBED`). With no
context, ADM does not fall back to the database user — every check refuses.

| Where your code runs | Call |
| --- | --- |
| A batch job, a script, a DBMS_SCHEDULER job — full privilege | `adm_context_api.system_login` |
| The same, but bounded by one user's permissions | `adm_context_api.system_user_login('JDOE')` |
| Your own APEX application's Initialization PL/SQL Code | `adm_context_api.establish_from_session` |
| A plug-in callback or ORDS handler that runs **outside** a page request | `adm_context_api.establish_for_callback(p_app_id, p_page_id, p_session_id)` |

```sql
begin
  adm_context_api.system_login;               -- acts as _UC_SYSTEM_, full privileges
  -- ... your work ...
  commit;
end;
/
```

`system_login` takes an optional debug level if you want ADM's own `apex_debug` output:

```sql
adm_context_api.system_login(p_debug_level => apex_debug.c_log_level_info);
```

Three things worth knowing:

- **`system_login` bypasses permission checks.** Prefer `system_user_login` when the work is
  being done *on behalf of* a person — then a folder they may not write is refused, which is
  usually what you want, and the audit log names them instead of `_UC_SYSTEM_`.
- **`apex_session.attach` does not run an application's initialization code.** If you attach a
  session yourself, call `establish_for_callback` (which clears, attaches and establishes in the
  right order) rather than attaching and hoping. Without it your code runs as whoever last used
  that pooled connection.
- **If you elevate mid-session, give the identity back.** Capture the current username and role,
  do the work, then `adm_context_api.restore_context(p_username => ..., p_role => ...)`. Otherwise
  the caller keeps the elevated role and every audit row after that names the wrong user.
  `adm_context_api.clear_context` leaves the session as nobody.

Read the current identity from the context rather than tracking it yourself:

```sql
l_username := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username);
```

## 2. You own the transaction

**No ADM package ever commits or rolls back.** That is deliberate, and it cuts both ways:

- Several ADM calls compose into one atomic unit — create a folder, upload three documents, tag
  them, and either all of it lands or none of it does.
- Nothing is persisted until **you** commit. A script that ends without a commit did nothing.
- When an ADM call raises, your transaction is still open and still yours to roll back.

```sql
begin
  adm_context_api.system_login;
  l_folder_id := adm_folder_api.add_folder(
    p_folder_name      => 'contracts'
  , p_parent_folder_id => adm_folder_api.get_folder_id('/')
  );
  -- more work here
  commit;
exception
  when others then
    rollback;
    raise;
end;
/
```

## 3. Read freely, write only through the APIs

**Reading** ADM's tables and views is supported and encouraged. Every table and column carries a
comment, so the model is explorable from the database itself:

```sql
select table_name, comments from user_tab_comments where table_name like 'ADM_%' order by 1;
select column_name, comments from user_col_comments where table_name = 'ADM_DOCUMENTS';
```

**Writing** goes through the packages, always. A direct `insert into adm_documents` produces a
document with no version, no content, no audit entry, no extracted metadata, no hook fired and no
storage policy applied — a row that looks like a document and behaves like nothing. The same is
true of `update` and `delete`: trashing a folder, for instance, has to mark a whole subtree and
revoke the shares and embed tokens that pointed into it.

## 4. Catch ADM's errors; raise your own in -20700 .. -20999

Every error ADM raises comes from `adm_error` (or `adm_ai_error` in the AI Pack) with a named
exception and a message meant for an end user. Three ways to handle one, in order of precision:

```sql
-- one specific error
exception
  when adm_error.e_doc_not_found then
    ...

-- a whole category, when several codes mean the same thing to you
exception
  when others then
    if adm_error.is_not_found(sqlcode) then ...
    elsif adm_error.is_no_permission(sqlcode) then ...
    else raise;
    end if;
```

The category predicates are `is_not_found`, `is_no_permission`, `is_conflict`,
`is_invalid_input`, `is_invalid_state`, plus `is_adm_error(sqlcode)` to tell an ADM error apart
from one raised by a bundled library. They all return a definite true or false, never null.

**Your own errors belong in `-20700 .. -20999`.** Every other `20xxx` range is taken: ADM uses
`-20100 .. -20299`, the AI Pack `-20600 .. -20699`, and bundled libraries the rest. Colliding
means your error is caught by a handler that thinks it is ADM's.

```sql
raise_application_error(-20700, 'A contract may not be filed without a case number');
```

## Staying upgradeable

An upgrade replaces every ADM object and re-imports the APEX application. These keep your work:

- **Do not modify ADM objects** — tables, views, packages, triggers. `install.sql` replaces them.
- **Do not modify the ADM APEX application.** Build your own and call the APIs.
- **Do not call anything marked `@private`** in the API reference. Those signatures change between
  releases without notice; the public ones do not.
- **Foreign keys to ADM tables must be `on delete cascade` or `on delete set null`.** A restricting
  constraint makes ADM's own delete fail, turning an ordinary user action into an error nobody can
  clear.
- **Ids are `number`, up to 32 decimal digits.** Never `integer`, never `pls_integer`.

Storing an ADM `folder_id` or `document_id` in your own tables to link the two worlds is supported
and is the intended way to connect a case, a claim or an order to its documents.

## Finding an API

The reference is generated from the installed package specs:
<https://united-codes.com/products/apex-document-management/docs/api/> — and
`/docs/ai-pack-api/` for the AI Pack. In the database itself:

```sql
select object_name, procedure_name from user_procedures
 where object_name like 'ADM%' and procedure_name is not null order by 1, 2;
```

Where to go next:

| Task | Skill |
| --- | --- |
| Upload, version, read content, retention, legal hold | `adm-documents` |
| Build a folder tree, move, trash, restore | `adm-folders` |
| Query what exists, list what a user may see, report | `adm-querying` |
| Tag documents, full-text and faceted search | `adm-search-and-tags` |
| Share with users and groups, public links, permission checks | `adm-sharing-and-permissions` |
| React to an upload or a folder creation | `adm-hooks` |
| Pack and expand zip archives | `adm-zip` |
| RAG over documents (AI Pack) | `adm-ai-rag` |
