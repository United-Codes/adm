---
name: adm-zip
description: >
  Packs and expands zip archives inside ADM (APEX Document Management) from PL/SQL with
  adm_zip_api: zip_document, zip_folder, unzip_document, where the result lands, the size and
  entry guards, and what to roll back when an extraction fails part-way. Use to zip a document
  or folder, import a .zip into a folder tree, "unzip into folder X", or archive a case folder.
  Not for streaming a multi-file download to a browser (the application's download dynamic
  action does that) and not for plain uploads (see adm-documents).
metadata:
  version: "26.2"
---

# Zip and unzip

Needs an established context and your own `commit` and `rollback` - see `adm-plsql`. Both
directions work on **stored ADM documents**: the archive is a real document, with versions, an
audit entry and permission checks. Nothing is streamed.

## Gotchas

1. **`unzip_document` has no target parameter.** It creates a folder named after the archive (name
   without extension) in the **archive's own folder**. To expand into folder X, either create the
   archive there (`zip_folder(p_target_folder_id => X)`) or `adm_document_api.move_document` it
   there first. See the recipe below.
2. **Unzipping next to the original merges into it.** An existing folder is reused. A document
   name that is taken gets `_restored` added (`a.txt` becomes `a_restored.txt`). Nothing is
   overwritten, and zipping the same folder twice gives `projects.zip`, then `projects_restored.zip`.
3. **Guards trip before anything is written.** Entry count, uncompressed size, archive size and
   every entry path are checked first, so a refused call leaves nothing behind. A **later**
   failure leaves a partial tree in your transaction: a hook that raises for one extracted file,
   `e_folder_exists`, or a name check. The refused document itself stays as well. Use a savepoint
   or roll back the whole transaction. `adm_zip_api` never does either.
4. **Hooks fire for every extracted document and for the archive** (`AFTER_NEW_FILE_UPLOAD`,
   see `adm-hooks`). A rule such as "no .exe" therefore also fails an extraction.
5. **`zip_folder` defaults the target to the folder's parent**, like a desktop file manager. It uses
   the folder itself when the folder is the root, a home folder under `/users`, or the caller has
   no EDIT right on the parent.
6. **A complete archive is not guaranteed.** `zip_folder` silently skips trashed, archived and
   not-viewable documents and trashed subfolders. The audit entry counts only the not-viewable
   ones. Count what you expect first when completeness matters.
7. **Entry paths are relative to the packed folder.** On unzip, a common top-level directory is
   dropped. An absolute path, a drive letter or a `..` segment fails the whole call with
   `e_invalid_name`. Zero-length entries are skipped, and empty directories are not created.
8. **Two different permission errors.** No view right on the source raises `e_no_view_right`. For
   the destination, `unzip_document` raises `e_no_edit_right` (the archive's folder is read-only),
   but `zip_document` and `zip_folder` raise `e_no_permission` (from `create_document`).
9. **Guard defaults:** `adm_zip_api.c_max_entries` (5000), `c_max_extracted_bytes` (2 GiB) and
   `c_max_archive_bytes` (2 GiB). Only `p_max_entries` and `p_max_extracted_bytes` can be lowered.

## Recipes

Pack a folder and unpack it into a chosen folder (replace the ids):

```sql
declare
  l_zip_id  adm_documents.document_id%type;
  l_root_id adm_folders.folder_id%type;
begin
  adm_context_api.system_user_login('JDOE');

  -- create the archive straight in the destination, then expand it there
  l_zip_id  := adm_zip_api.zip_folder(
                 p_folder_id        => 99
               , p_target_folder_id => 42
               );
  l_root_id := adm_zip_api.unzip_document(p_document_id => l_zip_id);
  -- l_root_id is the new folder 42/<archive name>
  commit;
end;
/
```

For an archive that already exists (an upload), move it first. The move raises `e_doc_exists` when
the destination already holds a document with that name.

```sql
adm_document_api.move_document(p_document_id => 4711, p_destination_folder_id => 42);
l_root_id := adm_zip_api.unzip_document(p_document_id => 4711);
```

`zip_document(p_document_id, p_target_folder_id)` packs one document into `<name>.zip` in its own
folder by default. Both zip functions return the new archive's document id.

Extract with a stricter limit and undo a partial tree on failure:

```sql
declare
  l_root_id adm_folders.folder_id%type;
begin
  adm_context_api.system_user_login('JDOE');
  savepoint before_unzip;
  l_root_id := adm_zip_api.unzip_document(
                 p_document_id         => 4711
               , p_max_entries         => 200
               , p_max_extracted_bytes => 50 * 1024 * 1024
               );
  commit;
exception
  when others then
    rollback to before_unzip;   -- removes a tree that a hook or a name check stopped half-way
    raise;
end;
/
```

## Errors

| Exception | Raised when |
| --- | --- |
| `e_doc_not_found` | document missing or in the trash |
| `e_no_current_version` | the document has no version to read |
| `e_folder_not_found` | folder missing or in the trash |
| `e_no_view_right` | caller may not read the source |
| `e_no_edit_right` / `e_no_permission` | destination not writable (see gotcha 8) |
| `e_not_an_archive` | the document is not a zip file |
| `e_archive_empty` | nothing readable to pack, or no files in the archive |
| `e_invalid_name` | unsafe entry path |
| `e_limit_exceeded` | any size or entry guard |
| `e_folder_exists` | a trashed folder holds a name the tree needs |
| `e_folder_trash_rule` | `zip_folder` on the trash folder; `unzip_document` on an archive that sits in the trash |

Look up other parameters with `select argument_name, data_type, in_out, defaulted from user_arguments
where package_name = 'ADM_ZIP_API' and object_name = 'UNZIP_DOCUMENT'`, or read the API reference.
