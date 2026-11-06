---
name: adm-plsql
description: >
  Rules for calling APEX Document Management (ADM) from your own PL/SQL, and the hub for the other
  adm-* skills. Covers the session context (adm_context_api: system_login, system_user_login), who
  owns the transaction, catching ADM errors (adm_error exceptions and category predicates), and
  what survives an upgrade. Read it before any code that calls an adm_ package, or any task about a
  document, folder, DMS or file store in this schema. Not the detail of documents, folders, search,
  sharing, hooks, zip, PDF, RAG or form extraction: see the routing table.
metadata:
  version: "26.2"
---

# Calling ADM from your own PL/SQL

ADM runs inside your Oracle database; every object starts with `adm_`. You call its PL/SQL packages
in your schema, or in one you have a grant on. There is no API key.

## Gotchas

1. **Without a context every check refuses.** ADM checks the session context (`ADM_CONTEXT`), never
   the database user. Writes raise `adm_error.e_no_permission` (-20121) and the `adm_my_*_v` views
   return zero rows. A few reads (`adm_folder_api.get_folder_id`, `adm_storage_api.get_file_content`)
   check nothing: do not use them as a permission check.
2. **`system_login` skips every permission check.** It acts as `_UC_SYSTEM_` with the ADMIN role. For
   work done for a person use `system_user_login('JDOE')`. It upper-cases the name, raises
   `e_user_not_found` for an unknown user and `e_no_permission` for a deactivated one, and clears
   the context first, so a failed login leaves no identity. A user with the ADMIN role gets the same
   bypass as `system_login`.
3. **The context role is not the access right.** Only ADMIN changes what the API allows. A user with
   the VIEW role and an EDIT share can still rename and version that document through the API (only the
   file browser refuses every write of a VIEW role). Real access comes from ownership (`/users/<name>/...`)
   and shares: see `adm-sharing-and-permissions`.
4. **You own the transaction.** The document, folder, tag, share and zip APIs never commit or roll
   back, so a script that ends without `commit` did nothing. After an ADM call raises, your
   transaction is still open: roll back the whole unit. These procedures commit, so keep them out of
   a unit of work: `adm_settings_api.configure_*`, `adm_job_automations_api`, `adm_ai_job_automations_api`.
   Some effects survive your rollback (autonomous transactions): a generated embed token, a failed
   link-share password attempt, the "cache outdated" flag.
5. **ADM errors are named exceptions, but your own SQL still raises Oracle errors.** Keep
   `no_data_found` and `dup_val_on_index` handlers for your own `select into` and `insert`. A value
   longer than its parameter type can raise `ORA-06502` before ADM validates it.
6. **Ids are `number` with up to 32 digits.** `integer` is safe. `pls_integer`, `binary_integer` (`ORA-01426`)
   and `number(n)` with n < 32 (`ORA-06502`) fail; JSON or JavaScript numbers lose digits: pass strings.
7. **Read freely, write only through the packages.** A direct `insert` or `update` on an ADM table
   skips versions, audit entry, hook, storage policy and share revocation. Every table and column
   has a comment (`user_col_comments`).
8. **`apex_session.attach` does not run the application's initialization code.** Without a new
   context the job runs as the last user of the pooled connection. Attach, then call `system_user_login`.
   `establish_for_callback` does clear, attach and `establish_from_session`.

## Recipes

Pick the context call by where the code runs:

| Where the code runs | Call |
| --- | --- |
| Script, scheduler job, migration with full privilege | `adm_context_api.system_login` |
| Same, limited to one user's rights | `adm_context_api.system_user_login('JDOE')` |
| Initialization PL/SQL Code of **your own** APEX application | the block below |
| Callback or ORDS handler in ADM's own application (APEX session id, no page request) | `adm_context_api.establish_for_callback(p_app_id, p_page_id, p_session_id)` |

`establish_from_session` is for ADM's own application. It reads the items `AI_USER_ROLE` and
`AI_EMBED_TOKEN`, which that application computes. In your own application, without an
`AI_USER_ROLE` item, it sets no identity and raises no error. Use this block instead. It leaves
the session without identity (every ADM check refuses) for `nobody` on the login page, for a user
missing from `adm_users` (`e_user_not_found`) and for a deactivated user (`e_no_permission`). Rows it
writes carry access source `DB`, not `APEX`.

```sql
-- Application > Initialization PL/SQL Code
begin
  adm_context_api.clear_context;           -- the pooled database session keeps the last user
  if lower(nvl(:APP_USER, 'nobody')) <> 'nobody' then
    adm_context_api.system_user_login(p_username => :APP_USER);
  end if;
exception
  when adm_error.e_user_not_found or adm_error.e_no_permission then
    null;
end;
```

Set `adm_context_api.clear_context` as the Cleanup PL/SQL Code too: the context belongs to the pooled
database session.

**A unit of work with error handling.** Catch by name for one case, by category for several.
`no_data_found` (`sqlcode` +100) is not an ADM error. Replace `JDOE` and the path.

```sql
declare
  l_folder_id adm_folders.folder_id%type;
begin
  adm_context_api.system_user_login('JDOE');
  l_folder_id := adm_folder_api.get_folder_id(p_folder_path => '/users/jdoe');
  -- ... calls to adm_ packages ...
  commit;
exception
  when adm_error.e_doc_exists then
    rollback;                                       -- one specific error
  when others then
    rollback;
    if    adm_error.is_not_found(sqlcode)     then null;   -- any "does not exist"
    elsif adm_error.is_no_permission(sqlcode) then null;   -- any refusal
    else  raise;
    end if;
end;
/
```

**Identity is session state: elevate, then give it back,** or the caller keeps the elevated role and
every later audit entry names the wrong user.

```sql
declare
  l_username varchar2(255 char) := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username);
  l_role     varchar2(30 char)  := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_role);
begin
  adm_context_api.system_login;
  -- ... privileged work ...
  adm_context_api.restore_context(p_username => l_username, p_role => l_role);   -- both null clears
end;
/
```

**Find ids.** There is no "find a document" API. `get_folder_id` takes a lower-case path without a
trailing slash and raises `e_folder_not_found`. Select a document by folder and name (case-sensitive);
the query ignores permissions, and the API call you make next checks them.

```sql
select d.document_id
  from adm_documents d
  join adm_folders f
    on f.folder_id = d.folder_id
 where f.folder_path = '/users/jdoe/contracts'
   and d.document_name = 'Contract 2026.pdf'
   and d.deleted_flag = 'N';
```

To list what one user may see, use the `adm_my_*_v` views (see `adm-querying`).

**Not-found demos a script can make** (bad id): `adm_storage_api.get_file_content` and
`adm_document_api.get_file_size` raise `e_version_not_found`; `rename_document`, `trash_document`,
`permanently_delete_document` and (as administrator) `add_comment` raise `e_doc_not_found`.
`user_is_allowed_to_view_document` of a nonexistent id is `true` in an ADMIN context (`system_login`
too), `false` otherwise: check existence yourself.

## Errors

| Handle with | Meaning |
| --- | --- |
| `adm_error.e_<name>` | One code. Each code has `c_err_*` (number), `c_msg_*` and `e_*`. |
| `is_not_found`, `is_no_permission`, `is_conflict`, `is_invalid_input`, `is_invalid_state` | Category of `sqlcode`: true or false, never null. `get_category` returns the name. |
| `is_adm_error(sqlcode)` | True for ADM and AI Pack errors. False for Oracle errors and bundled libraries. |
| `is_customer_error(sqlcode)` | True for -20700 to -20999, the range reserved for your code. |

Raise your own errors only in -20700 to -20999; every other `-20xxx` number belongs to ADM, the AI Pack
or a bundled library. A message from your range reaches the end user unchanged: no `sqlerrm`.

## Staying upgradeable

An upgrade replaces every ADM object and imports the APEX application again.

- Do not change ADM tables, views, packages or triggers, or the ADM APEX application.
- Do not call a declaration marked `@private` in the API reference. Its signature can change.
- A foreign key from your table to an ADM table must be `on delete cascade` or `on delete set null`.
  A restricting key makes the ADM delete fail with an error nobody can clear.
- Storing an ADM `folder_id` or `document_id` in your own table is supported.

## Routing

| Task | Skill |
| --- | --- |
| Upload, versions, read content, rename, trash, retention, legal hold | `adm-documents` |
| Folder tree, move, trash, restore | `adm-folders` |
| Query what exists, list what a user may see, report, audit trail, read a setting | `adm-querying` |
| Tags, full-text and faceted search | `adm-search-and-tags` |
| Share with users and groups, link shares, permission checks | `adm-sharing-and-permissions` |
| React to an upload, a delete, a move, a share or a retention event; refuse it | `adm-hooks` |
| Pack and expand zip archives | `adm-zip` |
| Merge, split, watermark, fill, sign PDFs; signing keys and folder signing policy | `adm-pdf` |
| RAG over documents (AI Pack) | `adm-ai-rag` |
| Extract fields from invoices and other PDF forms with a model (AI Pack) | `adm-ai-form-extraction` |

For any signature, use the generated reference (<https://united-codes.com/products/apex-document-management/docs/api/>,
`/docs/ai-pack-api/`) or the data dictionary:

```sql
select argument_name, data_type, in_out, defaulted from user_arguments
 where package_name = 'ADM_DOCUMENT_API' and object_name = 'CREATE_DOCUMENT' order by overload, position;
```
