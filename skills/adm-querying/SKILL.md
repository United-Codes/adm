---
name: adm-querying
description: >
  Reading data out of APEX Document Management (ADM) with SQL: the session-scoped adm_my_*_v views
  (what the logged-in user may see), the unfiltered adm_report_*_v reporting views, the core
  tables, access checks for one user, and linking ADM ids to your own tables. Use for an APEX
  report or REST feed over documents or folders, "documents this user can see", a storage or
  audit report, the audit trail of a document or user, reading a setting value from code, or a
  foreign key to adm_documents or adm_folders. Not for full-text or tag
  search (see adm-search-and-tags) and not for changing data (see adm-documents, adm-folders).
metadata:
  version: "26.2"
---

# Querying ADM

Reading ADM tables and views is supported. Writing goes through the packages. For contexts and
transactions see `adm-plsql`.

## Which source do I use?

| I need | Use |
| --- | --- |
| A list for the logged-in user: report, region, REST feed | `adm_my_*_v` (six views, below) |
| An administrator report over the whole instance | `adm_report_*_v` (twelve views, below) |
| "May user X see document Y", for one id or for another user | `adm_access_control_api` |
| Documents that match a word or a tag | `adm_search_api` (see `adm-search-and-tags`) |
| A column no view carries | the core tables, with the filters in gotcha 4 |

The six session views: `adm_my_documents_v` (with the latest version's number and size),
`adm_my_folders_v`, `adm_my_document_versions_v`, `adm_my_document_tags_v`,
`adm_my_document_annotations_v`, `adm_my_folder_annotations_v`.

The twelve report views, as `adm_report_<name>_v`: `documents`, `document_versions`, `folders`,
`document_shares`, `folder_shares`, `users`, `groups`, `tags`, `audit_log`, `file_type_analysis`,
`system_overview` (a key/value list of metrics, not one row) and `job_status`.

## Gotchas

1. **Only `adm_my_*_v` is filtered by user.** Every other view (`adm_report_*_v`,
   `adm_document_shares_v`, `adm_folder_shares_v`, `adm_ai_rag_*_v`) and every table returns all rows,
   whatever context is set. Never put one on a page a normal user can open.
2. **`adm_my_*_v` read the context and have no username parameter.** Without a context they return
   0 rows and no error. They return active rows only: a trashed or archived document is hidden,
   even from its owner. An administrator sees every active document and every folder that is not in
   the trash. Share-link and embed tokens are not honoured. Test a listing as an ordinary user.
3. **Your own APEX application must set the context itself.** Use the Initialization and Cleanup
   PL/SQL Code from `adm-plsql` (recipes); `establish_from_session` leaves such a session without identity.
4. **Report views and tables include trash and archive.** Filter `deleted_flag = 'N'` (set on every
   row below a trashed folder, not only on the folder you trashed) and, on documents,
   `archived_flag = 'N'`. `document_status` in `adm_report_documents_v` is one label for three
   independent flags: an archived document on legal hold reads `ARCHIVED`.
5. **`adm_storage_api.get_file_content` does not check access.** Any user can read any version id
   they pass in. Take the `version_id` from `adm_my_documents_v.latest_version_id` or
   `adm_my_document_versions_v`. Do not read `adm_document_versions.file_content`: it is empty for
   object storage. Each read writes a `READ_DOCUMENT` row to the audit trail (once per user,
   document and request, none for `_UC_SYSTEM_`), and the row survives a rollback.
6. **Do not rebuild access rules with joins.** Home folders, group folders, direct and inherited
   shares and the administrator role all grant access. Ask `adm_access_control_api`, or use the views.
   In an `ADMIN` context, including `system_login`, every check answers yes and ignores `p_username`.
   For another user's real answer, call `system_user_login` as that user and ask without `p_username`.
   A check per row suits a page of rows, not a million: narrow the set first.
7. **Check return types.** `user_is_allowed_to_view_document` and `is_allowed_to_view_folder`
   return `boolean`: call them from PL/SQL (SQL can use a boolean function only on 23ai and later; ADM also
   runs on 19c). In SQL use `is_allowed_to_view_folder_yn(...) = 'Y'`. `user_has_edit_rights_*` return
   `'EDIT'` or `'VIEW'`: compare with `adm_access_control_api.c_edit`. A user without any access gets
   `'VIEW'` too, so that value does not prove read access.
8. **Two helpers do not mean "everything this user can see".** `documents_in_shared_folders` and
   `folders_in_shared_folders` cover only subtrees of folders shared with the user. The share views
   list direct grants only. A missing row proves nothing: ownership, a share on an ancestor folder
   and the administrator role leave no row.
9. **Ids are `number` with up to 32 digits.** `integer` holds them. These do not: `pls_integer`,
   `binary_integer`, `number(n)` with n < 32, and a JSON or JavaScript number (a double). Hand ids
   to JavaScript as strings (`to_char`). A column that stores an ADM id needs a foreign key with
   `on delete cascade` or `on delete set null` (see `adm-plsql`).
10. **`like` on a path needs `adm_utils.escape_like`.** A folder name may contain `_` or `%`.

## Recipes

Run these after a context is set (`adm_context_api.system_login` in a script).

**1. APEX report: documents the session user may see, with folder path, size and latest version.**

```sql
select d.document_id
     , d.document_name
     , d.folder_path
     , d.latest_version_number
     , d.latest_file_size                                  -- bytes: a small file shows 0 in size_mb
     , round(d.latest_file_size / 1024 / 1024, 2) as size_mb
  from adm_my_documents_v d
 where d.folder_id = :P1_FOLDER_ID          -- or: d.folder_path like adm_utils.escape_like(:P1_PATH) || '/%' escape '\'
 order by d.document_name;
```

The init code for your own APEX application is in `adm-plsql`.

**2. Administrator report: storage per folder.**

```sql
select folder_path
     , count(*)                                       as documents
     , sum(latest_file_size)                          as bytes
     , round(sum(latest_file_size) / 1024 / 1024, 2)  as mb
  from adm_report_documents_v
 where deleted_flag = 'N'            -- archived documents still use storage, so they stay in
 group by folder_path
 order by bytes desc;
```

One folder with everything below it: add
`and (folder_path = :path or folder_path like adm_utils.escape_like(:path) || '/%' escape '\')`.
The sum above counts only each document's latest version. For all versions, sum `file_size` from
`adm_report_document_versions_v` instead. It has no `deleted_flag`, so it also counts documents in the trash.
By file type: `adm_report_file_type_analysis_v`.

**3. Visible documents that carry a tag value** (no cache delay, unlike `adm_search_api`):

```sql
select d.document_id, d.document_name
  from adm_my_documents_v d
 where exists (select 1
                 from adm_my_document_tags_v t
                where t.document_id = d.document_id
                  and t.tag_name    = 'department'      -- tag names are lower case
                  and t.tag_value   = 'Finance');       -- values keep their case
```

**4. Audit your own action** (the table is `adm_audit_log`, read it through `adm_report_audit_log_v`):

```sql
adm_audit_api.add_audit(
  p_action_type    => adm_audit_api.c_action_type_create_document   -- or your own text, up to 50 characters
, p_action_details => 'Filed automatically from case 2026-0042'     -- longer than 4000 characters is cut
, p_document_id    => l_document_id
, p_folder_id      => l_folder_id     -- without it the report shows no folder path for this row
);
```

**5. Audit trail and settings.** Admin reports, not session-scoped: the view returns every row.

```sql
select audit_id, action_date, action_type, user_id, user_access, action_details
  from adm_report_audit_log_v
 where document_id = :document_id            -- one document; or: user_id = upper(:username)
 order by action_date, audit_id;             -- audit_id is not chronological
```

`user_id` is the user name as text, upper case, not a number. Audit rows outlive the document: after
a permanent delete they stay, with `document_name` null. An action run under `system_login` is logged as `_UC_SYSTEM_`.
Share rows name the recipient by numeric id in `action_details`.

Read a setting with `adm_settings_api.get_setting_value(p_setting_key => 'CLEAN_TRASH_DAYS')`
(the column is `adm_settings.sett_value`) or a typed getter such as `get_clean_trash_days` and
`is_object_storage_enabled`. An unknown key returns null. Keys marked `is_admin_only` (credentials)
raise `e_admin_required` for a non-admin.

**6. Read column comments** (every table, view and column has one):

```sql
select c.column_name, c.comments
  from user_col_comments c
  join user_tab_columns t on t.table_name = c.table_name and t.column_name = c.column_name
 where c.table_name = 'ADM_MY_DOCUMENTS_V'
 order by t.column_id;
```

## Errors

| Exception | Raised when |
| --- | --- |
| `adm_error.e_user_not_found` | `system_user_login` for a name that is not in `adm_users` |
| `adm_error.e_no_permission` | `system_user_login` for a deactivated user |
| `adm_error.e_version_not_found` | `get_file_content` for an unknown `p_version_id` |
| `adm_error.e_admin_required` | `get_setting_value` of an `is_admin_only` key by a non-admin |
| `ORA-12899` (not an ADM error) | `add_audit` with a `p_action_type` longer than 50 characters |

Everything else: the generated reference at
<https://united-codes.com/products/apex-document-management/docs/views/> and `/docs/api/`. Parameters of a call:
`select argument_name, data_type, in_out, defaulted from user_arguments where package_name = 'ADM_X' and object_name = 'PROC'`.
For tables, read the comments (recipe 6).
