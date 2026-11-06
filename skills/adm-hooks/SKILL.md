---
name: adm-hooks
description: >
  Writes, registers and tests ADM (APEX Document Management) hooks - your PL/SQL that ADM calls
  on 13 events (14 with the AI Pack): AFTER_NEW_FILE_UPLOAD, AFTER_NEW_FILE_VERSION, AFTER_NEW_FOLDER_CREATION,
  AFTER_PDF_SIGNED, AFTER_FORM_EXTRACTION, and retention, delete, trash, move and share events.
  Use to refuse an upload (by name, extension, size or folder), to enforce a naming rule, to queue
  work when a file arrives or a folder is created, to warn before a retention ends or to veto a
  delete, or when a task mentions adm_hooks, hook_plsql or adm_hooks_api. Covers registering a hook
  from a script and why the caller must roll back a refusal. Not for plain uploads (see adm-documents).
metadata:
  version: "26.2"
---

# Hooks

A hook is a PL/SQL snippet stored in `adm_hooks.hook_plsql`. ADM runs it as dynamic PL/SQL with
the event's parameters bound by name. See `adm-plsql` for contexts and transaction ownership.

| Event (`adm_hooks.hook_key`) | Fires after | Binds |
| --- | --- | --- |
| `AFTER_NEW_FILE_UPLOAD` | a new document is created | `:p_document_id`, `:p_version_id` |
| `AFTER_NEW_FILE_VERSION` | a version is added to an existing document | `:p_document_id`, `:p_version_id` |
| `AFTER_NEW_FOLDER_CREATION` | a folder is created | `:p_folder_id` |
| `AFTER_PDF_SIGNED` | ADM signs a PDF and stores it (gotcha 11) | `:p_document_id`, `:p_version_id`, `:p_signing_key_id` |
| `AFTER_FORM_EXTRACTION` (AI Pack) | a form extraction ends `OK` or a person approves it (gotcha 11) | `:p_document_id`, `:p_version_id`, `:p_profile_id`, `:p_extraction_id`, `:p_status` |
| `RETENTION_ENDING_SOON` | the daily job: a retention ends in `RETENTION_WARNING_DAYS` (default 14, `0` = off) or fewer | `:p_document_id`, `:p_retention_end_date`, `:p_end_action`, `:p_days_left` |
| `RETENTION_ENDED` | the daily job: a retention ended | `:p_document_id`, `:p_retention_end_date`, `:p_end_action` |
| `BEFORE_DOCUMENT_DELETE` | before a document is deleted for good | `:p_document_id`, `:p_reason` (`MANUAL`, `RETENTION`, `FOLDER_DELETE`, `TRASH_CLEANUP`) |
| `AFTER_DOCUMENT_TRASHED` / `AFTER_DOCUMENT_RESTORED` | a document goes to or returns from the trash | `:p_document_id`, `:p_folder_id` |
| `AFTER_DOCUMENT_MOVED` | a document moves to another folder | `:p_document_id`, `:p_old_folder_id`, `:p_new_folder_id` |
| `AFTER_FOLDER_MOVED` | a folder moves to another parent | `:p_folder_id`, `:p_old_parent_folder_id`, `:p_new_parent_folder_id` |
| `AFTER_SHARE_CREATED` | a share row is created (one call per recipient) | `:p_share_type` (`DOCUMENT`, `FOLDER`, `LINK`), `:p_object_id`, `:p_share_id`, `:p_share_role`, `:p_shared_with_user_id`, `:p_shared_with_group_id` |
| `AFTER_RETENTION_CHANGED` | a retention of a document or folder changes | `:p_object_type` (`DOCUMENT`, `FOLDER`), `:p_object_id`, `:p_change` (`ADD`, `EXTEND`, `REMOVE`), `:p_retention_end_date`, `:p_period_value`, `:p_period_unit` |

## Gotchas

1. **A refusal is undone only by the caller.** The hook runs after the row is written, and ADM sets
   no savepoint. APEX rolls back a failed request. A script must `rollback` or `rollback to`
   a savepoint itself, or the refused document stays (a script that catches the error and commits keeps it).
2. **Name only the binds you need** (any subset of the event's binds, in a script and in an APEX
   session alike). A name in a comment or a string literal does not count.
3. **Only `-20700 .. -20999` reaches the caller as written.** Any other error from a hook,
   including `-20001`, becomes `e_hook_failed` (-20109) with a generic message; your message
   goes to the `apex_debug` log. Test with `adm_error.is_customer_error(sqlcode)`. Write the
   message for the end user, without `sqlerrm`.
4. **Registration replaces.** One `adm_hooks` row per event exists after install and holds one
   snippet. `update adm_hooks set hook_plsql = ...` is the one supported direct write to an ADM
   table. Read the old snippet first, and check `sql%rowcount`: an unknown `hook_key` updates
   nothing without an error. The row survives an upgrade. Set `hook_plsql` to null to unregister.
5. **The upload hook cannot see annotations** (`create_document` has no annotation parameter). Rule on
   name, extension, size or folder path. A rule on an annotation fits `AFTER_NEW_FILE_VERSION`.
6. **`AFTER_NEW_FILE_VERSION` also fires** for `create_document(p_overwrite => true)` on an existing
   name, for `restore_document_version`, and for a save in the version merge window (the new `p_version_id`
   replaces the old one, the old row is gone). Not when the content equals the latest version. A queue worker must expect a stale id.
7. **Every route fires the hooks**, including zip extraction (`adm-zip`): a refusing hook fails
   the extraction at the refused file. A PDF operation (`adm_pdf_api`) and a save in the PDF editor
   fire the upload or version hook for the file they store.
8. **A hook never commits**, except a refusal log in a `pragma autonomous_transaction` procedure.
9. **A hook that creates a folder or document starts the hooks again** (10 levels, then
   `e_hook_depth_exceeded`, not wrapped). Pass `p_run_hooks => false` to `add_folder`, `create_document` or
   `add_document_version`. Only an administrator or the system user may (else `e_admin_required`); an
   administrator can bypass a refusing hook the same way.
10. **Keep it short:** the user waits. Queue slow work, and send no mail or web request (a rollback does
    not undo them). `dbms_scheduler.create_job` commits the caller.
11. **`AFTER_PDF_SIGNED` fires only for a file that ADM signed itself:** a PDF operation result or an
    editor save in a folder with signing mode `SIGN` (see `adm-pdf`). It runs after the upload or version
    hook, once per signed file (a `split` into three parts runs it three times), and `p_run_hooks => false`
    skips it. An error from it fails the operation. A hook that changes the file adds a version that ADM did not
    sign (provenance `MODIFIED` or `NOT_SIGNED`). **`AFTER_FORM_EXTRACTION`** (see `adm-ai-form-extraction`): a refusal does
    not reach the extraction's caller, the result becomes `FAILED` with your message; for an approval the error is raised.
12. **The retention events run in the daily job**, as the system user, without an APEX session, once
    per document and end date (an extension gives a new end date and fires again). Trashed documents are
    skipped. For a `DELETE` retention, `RETENTION_ENDED` fires right before the delete and a
    `-20700 .. -20999` raise vetoes it: the job logs an error naming the document, deletes nothing for
    it, and tries again on its next run. A document under legal hold gets the event after the hold ends.
    A hook registered later gets `RETENTION_ENDED` once for every `RELEASE` retention that ended long ago.
13. **`BEFORE_DOCUMENT_DELETE` and the trash, move, share and retention-change events refuse the whole
    operation** when they raise `-20700 .. -20999`: a manual delete, "empty the trash", a folder delete (one call
    per document) and the retention delete all stop. `TRASH_CLEANUP` is only for a document trashed on its
    own; a trashed folder's documents get `FOLDER_DELETE`. Folder trash/restore, embed tokens, link share
    changes and legal holds fire no hook.

## Recipes

Register a hook that refuses `.exe` uploads. For more than a few lines, put the logic in your own
package (never in an ADM package: an upgrade replaces those) and register only the call, with both
binds: `my_adm_hooks.after_new_file_upload(p_document_id => :p_document_id, p_version_id => :p_version_id);`

An event holds one snippet, and another team's hook may already sit there. This block **chains**: the
old snippet runs first, then yours (if the old one refuses, yours does not run). Run twice, it adds
yours once (marker comment). To **replace**, first save `l_old` somewhere, then set `hook_plsql = l_new`.

```sql
declare
  l_old adm_hooks.hook_plsql%type;
  l_new adm_hooks.hook_plsql%type := q'[
-- hook: no-exe
declare
  l_name adm_documents.document_name%type;
begin
  select d.document_name
    into l_name
    from adm_documents d
    join adm_document_versions v
      on v.document_id = d.document_id
   where d.document_id = :p_document_id
     and v.version_id  = :p_version_id;

  if lower(l_name) like '%.exe' then
    raise_application_error(-20701, 'Executable files (.exe) cannot be uploaded.');
  end if;
end;]';
begin
  select hook_plsql
    into l_old
    from adm_hooks
   where hook_key = adm_hooks_api.c_after_new_file_upload
     for update;

  if l_old is null or instr(l_old, '-- hook: no-exe') = 0 then
    update adm_hooks
       set hook_plsql = case
                          when l_old is null then l_new
                          else 'begin' || chr(10) || l_old || chr(10) || l_new || chr(10) || 'end;'
                        end
     where hook_key = adm_hooks_api.c_after_new_file_upload;
  end if;

  commit;
end;
/
```

Prove it with one refused and one accepted upload (replace `JDOE`). The caller rolls back the
refusal. Check **whose** message it is: an older snippet runs first, so its refusal can hide
a hook of yours that never ran.

```sql
declare
  l_folder_id adm_folders.folder_id%type;
  l_doc_id    adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('JDOE');
  l_folder_id := adm_folder_api.get_folder_id(p_folder_path => '/users/jdoe');

  savepoint before_upload;
  begin
    l_doc_id := adm_document_api.create_document(
                  p_folder_id      => l_folder_id
                , p_document_name  => 'setup.exe'
                , p_file_content   => utl_raw.cast_to_raw('MZ')
                , p_file_mime_type => 'application/octet-stream'
                );
  exception
    when others then
      if not adm_error.is_customer_error(sqlcode) then
        raise;
      end if;
      dbms_output.put_line('refused: ' || sqlerrm);
      if instr(sqlerrm, 'Executable files (.exe)') = 0 then
        dbms_output.put_line('another hook refused first: your snippet was not tested');
      end if;
      rollback to before_upload;   -- until now the refused row is still there
  end;

  l_doc_id := adm_document_api.create_document(
                p_folder_id      => l_folder_id
              , p_document_name  => 'notes.txt'
              , p_file_content   => utl_raw.cast_to_raw('ok')
              , p_file_mime_type => 'text/plain'
              );
  dbms_output.put_line('accepted: ' || l_doc_id);
  commit;
end;
/
```

## Errors

| Exception | Raised when |
| --- | --- |
| your own `-20700 .. -20999` | your hook refuses; the caller sees number and message unchanged |
| `e_hook_failed` (-20109) | a hook raised anything else, or the snippet does not run |
| `e_hook_depth_exceeded` (-20112) | hooks nested more than 10 levels |
| `e_admin_required` (-20120) | a non-admin passed `p_run_hooks => false` |

`adm_hooks_api` has nothing to call: its `run_*` procedures belong to the product. Its constants
`c_after_new_file_upload`, `c_after_pdf_signed`, `c_retention_ended` etc. are the keys. For anything
else, read the API reference or query `user_arguments`.
