---
name: adm-zip
description: >
  Packing and expanding zip archives inside APEX Document Management (ADM) from PL/SQL -
  adm_zip_api.zip_document, zip_folder and unzip_document, their size guards, and the rollback
  the caller has to perform when a guard trips. Use whenever a task involves zipping an ADM
  document or folder, importing a zip file into a folder tree, or bulk-downloading ADM content.
  Read the adm-plsql skill first.
---

# Zip and unzip

Needs an established context and your own `commit` — see `adm-plsql`.

Everything here produces or consumes **stored ADM documents**. A zip made by `zip_folder` is a
real document: versioned, audited, permission-checked and subject to the target folder's storage
policy. Nothing is streamed to a browser.

> Streaming a multi-file download to the user is a different job, already covered by the
> `UNITEDCODES_DOWNLOAD_FILES_DA` dynamic action in the ADM application. Do not route that
> through this API.

## Pack

```sql
l_zip_document_id := adm_zip_api.zip_document(
  p_document_id      => 4711
, p_target_folder_id => null      -- defaults to the document's own folder
);
```

`report.pdf` produces `report.zip` holding one entry under the document's own name.

```sql
l_zip_document_id := adm_zip_api.zip_folder(
  p_folder_id        => 99
, p_target_folder_id => null      -- defaults to the folder's PARENT, like a desktop file manager
);
```

- Entry paths are **relative to the packed folder**, so a document in `child/grandchild` lands at
  `child/grandchild/report.pdf` rather than carrying an absolute path.
- Trashed subfolders, trashed documents, archived documents and **documents the caller may not
  view** are skipped silently — the call succeeds with fewer files. If completeness matters,
  count what you expected first.
- Nothing is ever overwritten. Zipping the same folder twice gives you `projects.zip` and then
  `projects_restored.zip`.
- EDIT rights on the target folder are required, and view rights are enforced per document.

## Expand

```sql
l_new_folder_id := adm_zip_api.unzip_document(p_document_id => l_zip_document_id);
```

A folder named after the archive is created **in the archive's own folder**, and the structure
inside is recreated below it. When every entry sits under one common top-level directory, that
directory is dropped — so an archive built by a desktop tool does not give you
`projects/projects/...`. Existing folders are reused rather than duplicated; a taken document name
gets a free one.

Entry paths are validated before anything is written. An absolute path, a drive letter or any
`..` segment fails the **whole call** with `adm_error.e_invalid_name` rather than being sanitized —
an archive containing one is not a mistake.

## The size guards, and the rollback they need

`unzip_document` refuses an archive that is too large, because any user with EDIT rights can
invoke it and a crafted archive can decompress to hundreds of times its own size:

| Guard | Default |
| --- | --- |
| `p_max_entries` | `adm_zip_api.c_max_entries` — 5000 entries |
| `p_max_extracted_bytes` | `adm_zip_api.c_max_extracted_bytes` — 2 GiB uncompressed |
| archive size, packing and unpacking | `adm_zip_api.c_max_archive_bytes` — 2 GiB |

You can lower them for a stricter policy:

```sql
l_folder_id := adm_zip_api.unzip_document(
  p_document_id         => l_zip_document_id
, p_max_entries         => 200
, p_max_extracted_bytes => 50 * 1024 * 1024
);
```

**A tripped guard is the caller's to undo.** `adm_zip_api` does not commit or roll back, so if
`unzip_document` raises `adm_error.e_limit_exceeded` part way through, the folders and documents it
already created are still in your transaction. Always wrap it:

```sql
declare
  l_folder_id adm_folders.folder_id%type;
begin
  adm_context_api.system_user_login('JDOE');

  l_folder_id := adm_zip_api.unzip_document(p_document_id => 4711);
  commit;
exception
  when others then
    rollback;          -- otherwise a half-extracted tree can still be committed later
    raise;
end;
/
```

The extracted tree is invisible to other sessions until you commit — which is what makes the
all-or-nothing behaviour possible.

## Errors worth catching

| Situation | Exception |
| --- | --- |
| Document missing or trashed | `adm_error.e_doc_not_found` |
| Folder missing or trashed | `adm_error.e_folder_not_found` |
| Caller may not read the source | `adm_error.e_no_view_right` |
| Caller may not write the destination | `adm_error.e_no_edit_right` |
| The document is not a zip file | `adm_error.e_not_an_archive` |
| Nothing readable to pack, or an empty archive | `adm_error.e_archive_empty` |
| Unsafe entry path in the archive | `adm_error.e_invalid_name` |
| Any size or entry guard | `adm_error.e_limit_exceeded` |
| A trashed folder holds a name the tree needs | `adm_error.e_folder_exists` |
| The trash folder itself | `adm_error.e_folder_trash_rule` |

Guide with worked examples:
<https://united-codes.com/products/apex-document-management/docs/using/zip/>
