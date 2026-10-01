---
name: adm-hooks
description: >
  Writing the PL/SQL behind an ADM (APEX Document Management) hook - the three events
  (AFTER_NEW_FILE_UPLOAD, AFTER_NEW_FILE_VERSION, AFTER_NEW_FOLDER_CREATION), how a hook runs
  inside the caller's transaction so raising aborts the operation, and how to register one. Use
  whenever a task asks to react to a file being uploaded or a folder being created in ADM, to
  enforce a rule ADM does not have, to reject an upload, or mentions adm_hooks or
  adm_hooks_api. Read the adm-plsql skill first.
---

# Hooks

A hook is your PL/SQL, called by ADM at the moment something happens. There are exactly three
events:

| Event | Fires after | Your procedure receives |
| --- | --- | --- |
| `AFTER_NEW_FILE_UPLOAD` | a new document is created | `p_document_id`, `p_version_id` |
| `AFTER_NEW_FILE_VERSION` | a version is added to an existing document | `p_document_id`, `p_version_id` |
| `AFTER_NEW_FOLDER_CREATION` | a folder is created | `p_folder_id` |

## Registering one

Hooks are registered in the **administration section of the ADM application**, which shows the
expected signature and an example for each event. What you store there is a **call**, not a
procedure body — ADM executes it as dynamic PL/SQL with the event's parameters bound by name:

```sql
my_adm_hooks.after_new_file_upload(
  p_document_id => :p_document_id
, p_version_id  => :p_version_id
);
```

So keep the snippet to one call and put the logic in your own package, where it is in version
control and can be compiled and tested.

## The two properties that decide how a hook behaves

**It runs inside the caller's transaction, after the operation is written but before it is
committed.** Therefore:

- **A hook that raises aborts the operation.** That is the supported way to enforce a rule ADM
  does not have — refuse an upload without a case number, refuse a folder whose name breaks your
  convention.
- **A hook must never `commit` or `rollback`.** The transaction is not its own; committing would
  persist half of ADM's work. (This is the same rule as for every ADM API — see `adm-plsql`.)
- Anything it writes lands atomically with the upload, which is exactly what you want for a row in
  your own linking table.

**It runs wherever the API does.** The same hook fires for a browser upload, a batch script and a
scheduled job, inside an APEX session and outside one. So do not read `v('P1_SOMETHING')` or
assume `apex_application.g_x01` is populated — take everything from the parameters and from the
database.

## A hook that records the upload

```sql
create or replace package body my_adm_hooks as

  procedure after_new_file_upload (
    p_document_id in number
  , p_version_id  in number
  )
  as
    l_document_name adm_documents.document_name%type;
    l_folder_path   adm_folders.folder_path%type;
  begin
    select d.document_name
         , f.folder_path
      into l_document_name
         , l_folder_path
      from adm_documents d
      join adm_folders f
        on d.folder_id = f.folder_id
     where d.document_id = p_document_id;

    -- Runs in ADM's transaction: this row and the document commit together.
    insert into my_document_inbox (document_id, version_id, folder_path, queued_at)
    values (p_document_id, p_version_id, l_folder_path, systimestamp);
  end after_new_file_upload;

end my_adm_hooks;
/
```

## A hook that refuses an upload

```sql
  procedure after_new_file_upload (
    p_document_id in number
  , p_version_id  in number
  )
  as
    l_folder_path adm_folders.folder_path%type;
  begin
    select f.folder_path
      into l_folder_path
      from adm_documents d
      join adm_folders f on d.folder_id = f.folder_id
     where d.document_id = p_document_id;

    if l_folder_path like '/cases/%'
       and not adm_annotations_api.document_annotation_exists(p_document_id, 'crm.case_id')
    then
      -- -20700 .. -20999 is the range reserved for customer code
      raise_application_error(
        -20700
      , 'A document filed under /cases must carry a case id. Set the crm.case_id annotation.'
      );
    end if;
  end after_new_file_upload;
```

The whole upload is rolled back and the user sees your message.

When your hook fails for any other reason, ADM logs the failure with its own message and backtrace
and re-raises it as its `hook failed` error, naming the hook — so the end user never sees a raw
`ORA-06512` from your package, but you still have the diagnostics in the debug log. Errors you
raise deliberately belong in **`-20700 .. -20999`**; every other `20xxx` range belongs to ADM, the
AI Pack or a bundled library.

## Things a hook should not do

- **Do not call the ADM API back in a way that re-triggers itself.** `AFTER_NEW_FILE_UPLOAD`
  calling `adm_document_api.create_document` fires the hook again, recursively.
- **Do not do slow work inline.** The user is waiting on the upload and holding a transaction
  open. Insert a queue row (as above) and let a scheduled job do the work.
- **Do not send mail or call a web service and expect it to be undone.** If the transaction rolls
  back afterwards, the mail is still sent. Queue it instead.
- **Do not rely on being the only hook.** One snippet per event is registered, so keep it a single
  dispatching call into your own code.

`adm_hooks_api` itself is only the runner — the `run_*` procedures are called by the product. There
is nothing in it for your code to call.

Full guide, including where to register and the exact signature ADM expects:
<https://united-codes.com/products/apex-document-management/docs/dev/hooks/>
