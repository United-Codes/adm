---
name: adm-documents
description: >
  Creating, versioning, reading and deleting documents in APEX Document Management (ADM) from
  PL/SQL - adm_document_api, reading file content through adm_storage_api.get_file_content,
  mime types, retention and legal hold, comments and annotations. Use whenever a task involves
  uploading a file into ADM, fetching a document's content back out, adding a version,
  renaming, trashing or permanently deleting a document, or setting a retention date or legal
  hold. Read the adm-plsql skill first for the context and transaction rules.
---

# Documents

Every call below needs an established context and your own `commit` — see the `adm-plsql`
skill. Nothing here commits.

A **document** (`adm_documents`) is a name in a folder plus a chain of **versions**
(`adm_document_versions`). The content belongs to the version, not to the document.
`adm_documents.latest_version_id` points at the current one.

## Create a document

```sql
declare
  l_document_id adm_documents.document_id%type;
  l_blob        blob;
begin
  adm_context_api.system_user_login('JDOE');   -- runs under JDOE's permissions

  l_blob := <your blob>;

  l_document_id := adm_document_api.create_document(
    p_folder_id       => adm_folder_api.get_folder_id('/users/jdoe/contracts')
  , p_document_name   => 'Contract 2026.pdf'
  , p_file_content    => l_blob
  , p_file_mime_type  => adm_mimetype_api.c_mime_pdf
  , p_overwrite       => false
  );

  commit;
end;
/
```

- The name **includes the extension**, and may contain spaces.
- `p_overwrite => false` (the default) raises when the folder already holds a document of that
  name. `p_overwrite => true` adds a new version to the existing document instead — which is what
  you want for an idempotent import that re-runs.
- EDIT rights on the target folder are required, unless you are in a `system_login` context.
- Creating a document fires the `AFTER_NEW_FILE_UPLOAD` hook (see the `adm-hooks` skill), writes
  an audit row, extracts `file.*` metadata, and — for a document that lands in object storage —
  queues its text for extraction. Full-text search over the *content* therefore lags the upload;
  everything else about the document is queryable immediately.

**Get the mime type right.** A wrong one changes which viewer opens the file and whether its text
is indexed. When the type you were handed is untrustworthy — an e-mail attachment, an HTTP upload,
a file read off disk — derive it from the content instead:

```sql
l_mime := adm_mimetype_api.get_corrected_mimetype(
  p_blob              => l_blob
, p_filename          => 'Contract 2026.pdf'
, p_reported_mimetype => l_reported            -- optional hint
);
```

It combines magic numbers, the extension and the reported type, and returns
`application/octet-stream` when it cannot tell. `adm_mimetype_api` also has a `c_mime_*` constant
for every common format — use those rather than typing the OOXML strings by hand.

## Add and restore versions

```sql
l_version_id := adm_document_api.add_document_version(
  p_document_id  => l_document_id
, p_file_content => l_new_blob
);
```

Fires `AFTER_NEW_FILE_VERSION`. The document keeps its name, id, tags and shares.

Rolling back to an old version does **not** delete anything — it copies that version's content
into a new one, so the history stays intact:

```sql
l_version_id := adm_document_api.restore_document_version(p_version_id => l_old_version_id);
```

## Read a document's content

Content lives either in a database BLOB or in OCI Object Storage, depending on the instance's
storage settings and the folder's policy. **Never select `adm_document_versions.file_content`
directly** — for an object-storage document that column is empty. Go through:

```sql
declare
  l_blob blob;
begin
  adm_context_api.system_user_login('JDOE');

  select adm_storage_api.get_file_content(
           p_version_id => d.latest_version_id
         , p_from_sql   => false                -- false when calling from PL/SQL
         )
    into l_blob
    from adm_documents d
   where d.document_id = 4711;
end;
/
```

`p_from_sql` defaults to `true`. Pass `false` whenever the call is made from PL/SQL rather than
from a plain SQL statement — it controls how the BLOB is handed back.

Two related helpers:

```sql
l_bytes := adm_document_api.get_file_size(p_version_id => l_version_id);
l_hash  := adm_document_api.calculate_checksum(p_blob => l_blob);   -- SHA-256, hex
```

`calculate_checksum` is the same function ADM uses to verify stored content, so comparing your own
hash against `adm_document_versions.checksum` is meaningful.

## Rename, move

```sql
adm_document_api.rename_document(p_document_id => 4711, p_new_name => 'Contract 2026 signed.pdf');
adm_document_api.move_document(p_document_id => 4711, p_destination_folder_id => 99);
```

Both take EDIT rights, and both **drop the embed tokens** that pointed at the old path — embed
tokens are keyed on a path, not on an id, so they would otherwise resolve against whatever takes
that path next. Internal shares and link shares survive a rename; a rename is not a revocation.

## Trash, restore, delete

Deletion is two-stage, exactly as in the UI.

```sql
-- 1. into the user's trash: reversible, still counted, still in the audit trail
adm_document_api.trash_document(p_document_id => 4711, p_user_id => 'JDOE');

-- 2. back out again, to its original folder
adm_document_api.restore_document(p_document_id => 4711);

-- or gone for good, content and all
adm_document_api.permanently_delete_document(p_document_id => 4711);
```

- `p_user_id` on `trash_document` is the **username** whose trash receives it, and it has to be
  the current context user's own — parking a row under someone else's home folder would hand them
  view and owner rights over it. An `ADMIN` context (which `system_login` is) may name anyone.
  Trashing also needs EDIT *and* owner rights on the document.
- Trashing or deleting revokes every grant on the document — internal shares, link shares and
  embed tokens — so restoring does not silently bring old access back to life.
- **Legal hold and retention block trashing as well as permanent deletion.** Expect
  `adm_error.e_legal_hold_active` / `e_retention_active`, not just at the final delete.

To drop a single old version rather than the document:

```sql
adm_document_api.delete_document_version(p_version_id => l_old_version_id);
```

You cannot delete the latest version — trash the document instead.

## Retention and legal hold

```sql
adm_document_api.add_file_retention(
  p_document_id           => 4711
, p_retention_delete_date => add_months(trunc(sysdate), 120)
, p_retention_category    => 'CONTRACTS'      -- optional, free text
);
adm_document_api.remove_file_retention(p_document_id => 4711);

adm_document_api.add_legal_hold(p_document_id => 4711);
adm_document_api.lift_legal_hold(p_document_id => 4711);
```

While either is in force the document cannot be trashed or deleted at all — the guard sits at the
top of `trash_document` too, so a workflow that files a document and then tidies up has to lift
the hold first. A retention date is what a scheduled ADM job later acts on to delete the document;
a legal hold has no end date and must be lifted deliberately.

## Comments and annotations

A **comment** is user-visible discussion. Adding one needs view rights — a reader who may open a
document may comment on it:

```sql
adm_document_api.add_comment(
  p_document_id         => 4711
, p_comment_text        => 'Signed copy received'
, p_document_version_id => null      -- null attaches to the current version
);
```

An **annotation** is a machine-readable key/value pair for your own processing — invisible to the
document UI, and the right place to record "this came from case 12345":

```sql
adm_annotations_api.add_document_annotation(
  p_document_id      => 4711
, p_annotation_key   => 'crm.case_id'     -- must be lowercase
, p_annotation_value => '12345'
);

if adm_annotations_api.document_annotation_exists(4711, 'crm.case_id') then
  l_case := adm_annotations_api.get_document_annotation(4711, 'crm.case_id');
end if;
```

`add_document_annotation` raises if the key is already there and `update_document_annotation`
raises if it is not, so check with `document_annotation_exists` when you mean "upsert". There are
`*_folder_annotation` equivalents for folders.

The **`file.` prefix is reserved.** ADM writes `file.title`, `file.author`, `file.page_count`,
`file.width` and friends itself when a file is uploaded. Read them freely; do not write them.

## Errors worth catching

| Situation | Exception |
| --- | --- |
| No such document, or it is in the trash | `adm_error.e_doc_not_found` |
| Caller may not read it | `adm_error.e_no_view_right` |
| Caller may not change it | `adm_error.e_no_permission` |
| Legal hold / retention in force | `adm_error.e_legal_hold_active` / `e_retention_active` |
| Trash named someone else's | `adm_error.e_doc_trash_rule` |

Or branch on a whole category with `adm_error.is_not_found(sqlcode)` /
`is_no_permission(sqlcode)`. See the `adm-plsql` skill.
