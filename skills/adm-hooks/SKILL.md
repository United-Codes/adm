---
name: adm-hooks
description: >
  Writes, registers and tests ADM (APEX Document Management) hooks - your PL/SQL that ADM calls
  on AFTER_NEW_FILE_UPLOAD, AFTER_NEW_FILE_VERSION, AFTER_NEW_FOLDER_CREATION and
  AFTER_PDF_SIGNED. Use to refuse an upload (by name, extension, size or folder), to enforce a
  naming rule, to queue work when a file arrives, a folder is created or ADM signs a PDF, or when
  a task mentions adm_hooks, hook_plsql or adm_hooks_api. Covers registering a hook from a script and why the caller must roll back a
  refusal. Not for plain uploads (see adm-documents).
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
| `AFTER_PDF_SIGNED` | ADM signs a PDF and stores it (see gotcha 11) | `:p_document_id`, `:p_version_id`, `:p_signing_key_id` |

## Gotchas

1. **A refusal is undone only by the caller.** The hook runs after the row is written, and ADM sets
   no savepoint. APEX rolls back a failed request. A script must `rollback` or `rollback to`
   a savepoint itself, or the refused document stays (a script that catches the error and
   commits keeps it).
2. **Name only the binds you need.** A snippet may use `:p_document_id`, `:p_version_id`, both or
   neither, in a script and in an APEX session alike. A name in a comment or a string literal does
   not count. Passing both to a call is always safe.
3. **Only `-20700 .. -20999` reaches the caller as written.** Any other error from a hook,
   including `-20001`, becomes `e_hook_failed` (-20109) with a generic message; your message
   goes to the `apex_debug` log. Test with `adm_error.is_customer_error(sqlcode)`. Write the
   message for the end user, without `sqlerrm`.
4. **Registration replaces.** The four `adm_hooks` rows exist after install, and each holds one
   snippet. `update adm_hooks set hook_plsql = ...` is the one supported direct write to an ADM
   table (the application's hook page stores its snippet in the same column). Read the old snippet first, and check
   `sql%rowcount`: an unknown `hook_key` updates nothing without an error. The row survives an
   upgrade. Set `hook_plsql` to null to unregister.
5. **The upload hook cannot see annotations.** `create_document` has no annotation parameter, so
   none exist yet. Rule on name, extension, size or folder path. A rule on an annotation fits
   `AFTER_NEW_FILE_VERSION`, where the document already exists.
6. **`AFTER_NEW_FILE_VERSION` also fires** for `create_document(p_overwrite => true)` on an
   existing name, for `restore_document_version`, and for a save in the version merge window
   (the new `p_version_id` replaces the old one, and the old row is gone). It does not fire when
   the content equals the latest version. A queue worker must expect a stale id.
7. **Every route fires the hooks**, including zip extraction (`adm-zip`): a refusing hook fails
   the extraction at the refused file. A PDF operation (`adm_pdf_api`) and a save in the PDF editor
   fire the upload or version hook for the file they store.
8. **A hook never commits**, except a refusal log in a procedure with `pragma autonomous_transaction`.
   A refused upload leaves no other trace.
9. **A hook that creates a folder or document starts the hooks again** (limit: 10 levels, then
   `e_hook_depth_exceeded`, which is not wrapped). Pass `p_run_hooks => false` to `add_folder`,
   `create_document` or `add_document_version`. Only an administrator or the system user may; anyone
   else gets `e_admin_required`. An administrator can bypass a refusing hook the same way.
10. **Keep it short.** The user waits for the hook. Queue slow work, and do not send mail or call a
    web service (a rollback does not undo them). `dbms_scheduler.create_job` commits the caller.
11. **`AFTER_PDF_SIGNED` fires only for a file that ADM signed itself.** That is a PDF operation
    result or a PDF editor save in a folder with the signing mode `SIGN` (a signing policy, see the
    admin documentation). It runs after the upload or version hook of the same file, once for each
    signed file (a `split` into three parts runs it three times). `p_signing_key_id` is the key of
    the setting `AUTO_SIGN_KEY_ID`. `protect`, `sign`, `to_images` and `get_attachments` do not
    fire it, and `p_run_hooks => false` of the operation skips it. An error from it fails the
    operation. A hook that changes the file adds a version that ADM did not sign: its provenance
    is `MODIFIED` or `NOT_SIGNED` (`adm_pdf_api.get_provenance`).

## Recipes

Register a hook that refuses `.exe` uploads. For more than a few lines, put the logic in your own
package (never in an ADM package: an upgrade replaces those) and register only the call, with both
binds: `my_adm_hooks.after_new_file_upload(p_document_id => :p_document_id, p_version_id => :p_version_id);`

An event holds one snippet, and another team's hook may already sit there. This block **chains**: the
old snippet runs first, then yours (if the old one refuses, yours does not run). Run twice, it adds
yours once, because of the marker comment. To **replace** instead, first save `l_old` (your own table
or a file under version control), then set `hook_plsql = l_new`.

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
  l_count     number;
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
      select count(*) into l_count from adm_documents
       where folder_id = l_folder_id and document_name = 'setup.exe';
      dbms_output.put_line('rows before rollback: ' || l_count);   -- 1: the row is still there
      rollback to before_upload;                                    -- now it is gone
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
`c_after_new_file_upload`, `c_after_new_file_version`, `c_after_new_folder_creation` and
`c_after_pdf_signed` are the keys. For anything else, read the API reference or query
`user_arguments`.
