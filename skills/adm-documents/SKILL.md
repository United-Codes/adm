---
name: adm-documents
description: >
  Create, version, read, rename, move, trash, restore and permanently delete documents in APEX
  Document Management (ADM) from PL/SQL: adm_document_api, adm_storage_api.get_file_content,
  adm_mimetype_api, retention, legal hold, comments and annotations (adm_annotations_api). Use for
  any task that uploads a file into ADM, reads file content back (as BLOB or text), adds or
  restores a version, or deletes a document. Context, transaction and error basics are in
  adm-plsql. Not folder trees (adm-folders), shares (adm-sharing-and-permissions) or search
  (adm-search-and-tags).
metadata:
  version: "26.2"
---

# Documents

Read `adm-plsql` first: every call needs a context and your own `commit`. A **document**
(`adm_documents`) is a name in a folder plus a chain of **versions** (`adm_document_versions`).
The content belongs to the version. `adm_documents.latest_version_id` points at the current one.

## Gotchas

1. **Read content with a PL/SQL assignment, never `select ... into`.**
   `l_blob := adm_storage_api.get_file_content(p_version_id => ..., p_from_sql => false)`. For
   object storage, `false` queues text extraction, which is DML and raises `ORA-14551` inside a
   query. Never read `adm_document_versions.file_content` yourself: it is empty for object storage.
2. **`get_file_content` does not check access.** Take the version id from `adm_my_documents_v`
   (`latest_version_id`) or `adm_my_document_versions_v`, or call
   `adm_access_control_api.user_is_allowed_to_view_document(p_document_id => ...)` first.
3. **File content is a BLOB, so you convert text yourself.** `utl_raw.cast_to_raw` is enough for a
   short string. Use `apex_util.clob_to_blob(p_clob, p_charset => 'AL32UTF8')` and
   `apex_util.blob_to_clob(p_blob, p_charset => 'AL32UTF8')` for anything longer or non-ASCII.
4. **A document name includes its extension and is checked.** It is trimmed without notice, may
   hold spaces and colons, and must not hold `< > " / \ | ? *` or control characters
   (`e_invalid_name`). Names are case-sensitive: `A.txt` and `a.txt` can share a folder. A name over
   255 characters raises `e_invalid_name`. A duplicate in the folder raises `e_doc_exists`.
5. **`p_overwrite => true` adds a version to the existing document.** It ignores
   `p_file_mime_type`, and fires `AFTER_NEW_FILE_VERSION` instead of `AFTER_NEW_FILE_UPLOAD`.
6. **A new version does not always get a new row.** Identical content adds nothing and returns the
   latest `version_id`. With setting `VERSION_MERGE_WINDOW_MINUTES` above 0, a save by the same user
   inside the window replaces the latest version and deletes its `version_id`: do not keep ids.
   `p_allow_merge => false` always adds one.
7. **Rights differ per call.** With no context every call raises `e_no_permission`.
   - Create needs EDIT on the folder. Rename, add version and delete version need EDIT on the
     document: an EDIT share is enough, even for a user with the VIEW role. A comment needs view
     rights. `move_document` needs EDIT on both folders.
   - Trash, restore, permanent delete, retention, legal hold: **owner** rights. An EDIT share is not
     enough. A move into another owner's tree (`/users/<name>`, `/groups/<name>`) needs them too.
8. **A trashed document is out of the live set.** It is "not found"
   (`e_doc_not_found`) for rename, add version, trash and move. Trashing revokes every share, link
   share and embed token, and restoring does not bring them back. A document that fell into the
   trash with its folder cannot be restored alone (`e_doc_trash_rule`). On a name clash
   `restore_document` renames to `name_restored.ext`.
9. **`trash_document(p_user_id => ...)` must name the current user.** Others get `e_doc_trash_rule`;
   only ADMIN may name another user. `permanently_delete_document` works only on a trashed
   document. Object-storage content is deleted later by a job. The daily job also deletes trash
   older than setting `CLEAN_TRASH_DAYS` (30 by default).
10. **Retention and legal hold block deletion.** A retention date blocks `trash_document`
    (`e_retention_active`) until it has passed and the end action is `DELETE` (the default): then
    it blocks until the daily job has hard-deleted the document, skipping the trash. With
    `p_end_action => 'RELEASE'` the document stays and is normal after the date. ADM does not check
    that the date lies ahead. A legal hold blocks trash, delete, `delete_document_version` and
    `add_file_retention`. Lift or remove it first. A retention rule or hold on a **folder** covers
    the document as well (see `adm-folders`), so a document can be protected with
    `retention_delete_date` null. Read `adm_report_documents_v` (`effective_retention_date`,
    `under_legal_hold`) for the result.
    A `p_system => true` item needs ADMIN (`e_system_admin_required`). Nobody can remove a running
    system retention (`e_system_retention_locked`). Extend it with `extend_file_retention`.
11. **Skip hooks only as admin.** `p_run_hooks => false` raises `e_admin_required` for others. A hook
    runs in your transaction, and a failing hook aborts the call (see `adm-hooks`).
12. **Text search over new content lags.** Extraction is queued per storage location when its
    index setting is on and the mime type carries text. Everything else is queryable at once.
13. **Annotation keys are lowercased and `file.` is reserved.** ADM writes `file.*` keys itself and
    deletes stale ones at the next extraction. `get_document_annotation` returns null when the
    caller may not view the document and raises `e_annotation_not_found` when the key is missing.

## Recipes

Replace the user, the folder path and the ids. Create the folder first (see `adm-folders`).

**Upload text, read it back, add a version.**

```sql
declare
  l_folder_id   adm_folders.folder_id%type;
  l_document_id adm_documents.document_id%type;
  l_version_id  adm_document_versions.version_id%type;
  l_blob        blob;
  l_text        clob;
begin
  adm_context_api.system_user_login('JDOE');
  l_folder_id := adm_folder_api.get_folder_id(p_folder_path => '/users/jdoe');

  l_document_id := adm_document_api.create_document(
    p_folder_id      => l_folder_id
  , p_document_name  => 'Note 1.txt'
  , p_file_content   => utl_raw.cast_to_raw('Hello')
  , p_file_mime_type => adm_mimetype_api.c_mime_text
  , p_overwrite      => false
  );

  select latest_version_id
    into l_version_id
    from adm_my_documents_v
   where document_id = l_document_id;               -- no_data_found: caller may not see it
  l_blob := adm_storage_api.get_file_content(p_version_id => l_version_id, p_from_sql => false);
  l_text := apex_util.blob_to_clob(p_blob => l_blob, p_charset => 'AL32UTF8');

  l_version_id := adm_document_api.add_document_version(
    p_document_id  => l_document_id
  , p_file_content => utl_raw.cast_to_raw('Hello again')
  );
  commit;
end;
/
```

For an upload you did not create yourself, derive the mime type from the content (it returns
`application/octet-stream` when unsure; `adm_mimetype_api` has a `c_mime_*` constant per format):

```sql
l_mime := adm_mimetype_api.get_corrected_mimetype(
  p_blob => l_blob, p_filename => 'Contract.pdf', p_reported_mimetype => l_reported);
```

**Roll back to an old version.** This copies its content into a new version; history stays.

```sql
l_version_id := adm_document_api.restore_document_version(p_version_id => l_old_version_id);
```

**Rename, move, trash, restore, delete.** Find `l_document_id` as shown in `adm-plsql`.

```sql
adm_document_api.rename_document(p_document_id => l_document_id, p_new_name => 'Note 2.txt');
adm_document_api.move_document(p_document_id => l_document_id, p_destination_folder_id => l_other_folder_id);
adm_document_api.trash_document(p_document_id => l_document_id, p_user_id => 'JDOE');
adm_document_api.restore_document(p_document_id => l_document_id);     -- back to the old folder
adm_document_api.trash_document(p_document_id => l_document_id, p_user_id => 'JDOE');
adm_document_api.permanently_delete_document(p_document_id => l_document_id);
```

Rename to the same name raises `e_invalid_name`. Moving to the current folder does nothing. Rename
and move drop the embed tokens of the old path, not the shares. To remove one old version, call
`adm_document_api.delete_document_version(p_version_id => ...)`. It cannot delete the latest
(`e_invalid_state`).

**Retention, legal hold, comment, annotation.**

```sql
adm_document_api.add_file_retention(
  p_document_id => l_document_id, p_retention_delete_date => add_months(trunc(sysdate), 120)
, p_retention_category => 'CONTRACTS', p_end_action => 'RELEASE');
adm_document_api.extend_file_retention(
  p_document_id => l_document_id, p_retention_delete_date => add_months(trunc(sysdate), 144));
adm_document_api.remove_file_retention(p_document_id => l_document_id);
adm_document_api.add_legal_hold(p_document_id => l_document_id);
adm_document_api.lift_legal_hold(p_document_id => l_document_id);

adm_document_api.add_comment(p_document_id => l_document_id, p_comment_text => 'Signed copy received');

adm_annotations_api.add_document_annotation(
  p_document_id => l_document_id, p_annotation_key => 'crm.case_id', p_annotation_value => '12345');
if adm_annotations_api.document_annotation_exists(l_document_id, 'crm.case_id') then
  l_case := adm_annotations_api.get_document_annotation(l_document_id, 'crm.case_id');
end if;
```

`add_document_annotation` raises `e_annotation_exists` for an existing key and
`update_document_annotation` raises `e_annotation_not_found` for a missing one: check with
`document_annotation_exists` for an upsert. `*_folder_annotation` procedures work the same for folders.

## Errors

| Exception | Raised when |
| --- | --- |
| `e_doc_not_found` (not found) | Unknown or trashed id, in create-version, rename, move, trash, restore, delete, retention, hold |
| `e_version_not_found` (not found) | Unknown version in `get_file_content`, `get_file_size`, `restore_document_version`, `delete_document_version` |
| `e_folder_not_found` (not found) | Unknown folder in `create_document` or `move_document` |
| `e_doc_exists` (conflict) | The name is taken in the folder (create, rename, move) |
| `e_invalid_name` (invalid input) | Name rule broken, or rename to the current name |
| `e_doc_trash_rule` (invalid state) | Restore of a live document, trash for another user, permanent delete of a live document |
| `e_legal_hold_active`, `e_retention_active` (invalid state) | Trash or delete of a protected document |
| `e_system_admin_required` (no permission), `e_system_retention_locked` (invalid state) | System hold or retention by a non-admin, or removal of a running system retention |
| `e_no_permission` (no permission) | No context, or rights are too low. Comments on an unknown document give this too. |
| `e_limit_exceeded` (invalid input) | File larger than setting `FS_UPLOAD_MAX_FILE_BYTES` |

For several codes at once, use `adm_error.is_not_found(sqlcode)` and the other predicates.
For any other signature, query `user_arguments` for `ADM_DOCUMENT_API` (see `adm-plsql`) or read
the generated API reference.
