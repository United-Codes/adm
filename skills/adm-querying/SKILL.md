---
name: adm-querying
description: >
  Reading data out of APEX Document Management (ADM) with SQL - the session-scoped adm_my_*_v
  integration views, the unfiltered adm_report_*_v reporting views, the core tables and their
  column comments, filtering a query down to what one user is allowed to see, and joining ADM
  ids to your own tables. Use whenever a task involves reporting on ADM content, listing
  documents or folders, building an APEX report or a REST feed over ADM data, counting storage,
  or linking an ADM document_id or folder_id to an application table. Read the adm-plsql skill
  first.
---

# Querying ADM

Reading ADM's tables and views is supported. Writing is different: it goes through the
packages, always (see `adm-plsql`).

## Pick the right family of views first

The prefix is the access scope, and getting it wrong is the one mistake here that leaks data.

| Prefix | Scope | Use for |
| --- | --- | --- |
| `adm_my_*_v` | Only what the ADM user established in the current session may see. Identity comes from the context; no username parameter. No context, no rows. | Anything a user looks at: a report, a region, a REST feed |
| `adm_report_*_v` | Every row in the instance, whoever is asking. Establishing a context does **not** narrow it. | Administrative reports, dashboards, data audits |

**Do not put an `adm_report_*_v` view on a user-facing page.** It will list every document in
the instance to whoever runs it.

### The session-scoped integration views

Six of them. They resolve access once, as a set-based semi-join, not per row.

| View | One row per | Unique by |
| --- | --- | --- |
| `adm_my_documents_v` | active document the session may see, with its current version's metadata | `document_id` |
| `adm_my_folders_v` | folder the session may see | `folder_id` |
| `adm_my_document_tags_v` | tag on a visible document, `tag_name` resolved | `document_tag_id` |
| `adm_my_document_versions_v` | version of a visible document, metadata only | `version_id` |
| `adm_my_document_annotations_v` | annotation on a visible document | `annotation_id` |
| `adm_my_folder_annotations_v` | annotation on a visible folder | `annotation_id` |

```sql
-- everything in one folder that this user may see
select document_id, document_name, file_mime_type, latest_file_size
  from adm_my_documents_v
 where folder_id = :P1_FOLDER_ID
 order by document_name;
```

Four things to know before building on them:

- **Active only.** A trashed or archived document is never returned, not even to its owner —
  even though `adm_access_control_api.user_is_allowed_to_view_document` does still allow the
  owner of a document in their own trash.
- **Administrators see every active document and every non-trashed folder**, matching the
  access API's admin bypass. Test a listing as an ordinary user, never as an administrator.
- **Share-URL tokens and embed tokens are not honoured.** Those routes stay with
  `adm_link_shares_api` and the embed pages.
- **Establish the context, and clear it again.** In your own APEX application that means
  `adm_context_api.system_user_login(:APP_USER)` as the Initialization PL/SQL Code *and*
  `adm_context_api.clear_context` as the Cleanup PL/SQL Code. The context is scoped to the
  database session and an APEX session comes from a connection pool, so skipping the cleanup
  hands the next request the previous user's identity.

Relationship views cannot leak: a count over `adm_my_document_tags_v` for a tag used only on an
inaccessible document is zero, while `adm_report_tags_v.documents_count` counts it.

### The administrative reporting views

There are 12 `adm_report_*_v` views. They already join the pieces you would otherwise assemble
by hand — a document with its latest version, a share with its recipient, an audit row with its
asset — and every view and column carries a comment. None of them filters by access.

| View | For |
| --- | --- |
| `adm_report_documents_v` | Documents with owner, status, mime type, and the latest version's size |
| `adm_report_document_versions_v` | Version history and per-version sizes |
| `adm_report_folders_v` | The hierarchy with content counts |
| `adm_report_document_shares_v`, `adm_report_folder_shares_v` | Who has been given access to what |
| `adm_report_users_v`, `adm_report_groups_v` | Users and groups with ownership and sharing counts |
| `adm_report_tags_v` | Tag usage |
| `adm_report_audit_log_v` | The audit trail, with categorized actions and time buckets |
| `adm_report_file_type_analysis_v` | Storage consumption by mime type |
| `adm_report_system_overview_v` | One-row instance summary |
| `adm_report_job_status_v` | Scheduled job health |

The two share views deserve a warning of their own: `adm_document_shares_v`,
`adm_folder_shares_v` and their `adm_report_*` counterparts hold **direct grants only**.
Ownership, group ownership, a share inherited from an ancestor folder and the admin bypass all
grant access without leaving a row, so the absence of a row proves nothing.

```sql
select column_name, comments
  from user_col_comments
 where table_name = 'ADM_MY_DOCUMENTS_V'
 order by column_id;
```

Full descriptions: <https://united-codes.com/products/apex-document-management/docs/views/> ·
worked examples:
<https://united-codes.com/products/apex-document-management/docs/dev/querying-adm-from-sql/>

## The core tables

Query them directly when a view does not carry what you need. The ones you will actually touch:

| Table | Holds |
| --- | --- |
| `adm_documents` | One row per document: `document_name`, `folder_id`, `file_mime_type`, `latest_version_id`, `user_owner`, `group_owner`, `deleted_flag`, `archived_flag`, `legal_hold_flag`, `retention_delete_date` |
| `adm_document_versions` | One row per version: `version_number`, `file_size`, `checksum`. **Read content via `adm_storage_api.get_file_content`, not the BLOB column** — it is empty for object-storage documents |
| `adm_folders` | The tree: `folder_path`, `parent_folder_id`, `is_system_folder`, `deleted_flag`, `trash_root_flag` |
| `adm_users`, `adm_roles`, `adm_groups`, `adm_group_members` | Identity |
| `adm_document_shares`, `adm_folder_shares`, `adm_document_link_shares`, `adm_embed_tokens` | Granted access |
| `adm_tags`, `adm_document_tags` | Tags and their values |
| `adm_document_annotations`, `adm_folder_annotations` | Key/value metadata, including ADM's own `file.*` keys |
| `adm_audit_log` | Every recorded action |

Two filters belong on nearly every query over documents or folders:

```sql
  where deleted_flag = 'N'      -- 'Y' means "is in the trash", for a whole trashed subtree
    and archived_flag = 'N'     -- adm_documents only
```

`deleted_flag = 'Y'` is set on every descendant of a trashed folder, not only on the folder you
trashed — so omitting it does not show you "a few deleted rows", it shows you whole subtrees users
believe they have thrown away.

When you build a path predicate yourself, escape the pattern — a folder name may legitimately
contain `_` or `%`:

```sql
where f.folder_path like adm_utils.escape_like(l_prefix) || '/%' escape '\'
```

## Restricting a query to one user

Nothing in a plain `select` over the **tables** or the `adm_report_*_v` views enforces ADM's
permissions. Home folders, group folders, direct shares, shares inherited from a parent folder
and the admin bypass all feed into the answer, so do not attempt to reproduce it with joins.

**The first answer is an `adm_my_*_v` view** — it has already done this, once, as a semi-join.
Reach for the options below only when a view cannot carry what you need: when you are asking
about a *different* user than the session's, when the trash or the archive is in scope, or when
you have a single id in PL/SQL and no row source to hang the check on.

**Ask per row.** `adm_access_control_api` answers from the current context by default, so most
calls take only an id. Mind which functions are callable from SQL:

```sql
-- folders: the _yn variant returns 'Y'/'N', so it works in SQL and in APEX conditions
select f.folder_id, f.folder_path
  from adm_folders f
 where f.deleted_flag = 'N'
   and adm_access_control_api.is_allowed_to_view_folder_yn(p_folder_id => f.folder_id) = 'Y';
```

`user_is_allowed_to_view_document` and `is_allowed_to_view_folder` return **`boolean`**, which is
not callable from SQL before Oracle 23ai — and ADM runs on 19c too. Call those from PL/SQL:

```sql
for r in (select document_id from adm_documents where folder_id = l_folder_id and deleted_flag = 'N') loop
  if adm_access_control_api.user_is_allowed_to_view_document(p_document_id => r.document_id) then
    ...
  end if;
end loop;
```

`user_has_edit_rights_on_document` and `user_has_edit_rights_on_folder` return `varchar2` — compare
against `adm_access_control_api.c_edit` — so they are usable in SQL on any supported release.

All of them accept an explicit `p_username` when you are reporting *about* another user rather than
*as* them. Related helpers, both pipelined:

```sql
select column_value as document_id
  from table(adm_access_control_api.documents_in_shared_folders(p_username => 'JDOE'));

select column_value as folder_id
  from table(adm_access_control_api.folders_in_shared_folders(p_username => 'JDOE'));
```

**Ask in bulk, with a search** — `adm_search_api.search_user_documents` returns only what the named
user may see and takes a full-text expression and tag facets. See the `adm-search-and-tags` skill.

Per-row checks are fine for a report page's worth of rows and a poor idea across a million: they
are functions, not joins, and the optimizer cannot see through them. For large scans, restrict the
set first (a folder subtree, a date range, a search) and let the check filter what survives.

<!-- Not part of the documented API: the product's own listings are built on SQL macros such as
     adm_user_accessible_documents_mcr(p_username) and adm_user_accessible_folders_mcr(p_username).
     They are not in the published reference and may change between releases, so ask United Codes
     before building on them rather than treating them as public. -->

## Linking ADM to your own tables

Storing an ADM `document_id` or `folder_id` in your table is the intended way to connect a case, a
claim or an order to its documents.

```sql
create table case_documents (
  case_id     number not null
, document_id number not null
, constraint case_documents_doc_fk foreign key (document_id)
    references adm_documents (document_id) on delete cascade
);
```

Two rules, both load-bearing:

- **`on delete cascade` or `on delete set null` — never restricting.** A restricting constraint
  makes ADM's own delete fail, which turns an ordinary user action into an error nobody can clear.
- **`number`, never `integer`.** Ids run to 32 decimal digits.

If a document may be absent, prefer `on delete set null` and keep your own row; if the link has no
meaning without the document, cascade.

## Auditing your own actions

If your workflow does something a reviewer will later ask about, put it in ADM's audit trail
rather than a log table of your own:

```sql
adm_audit_api.add_audit(
  p_action_type    => adm_audit_api.c_action_type_create_document
, p_action_details => 'Filed automatically from case 2026-0042'
, p_document_id    => l_document_id
);
```

The row is stamped with the current context identity and access channel. `adm_audit_api` has a
`c_action_*` constant for every action type ADM itself records; reuse the closest one so the audit
report categorizes your row rather than dropping it into an "other" bucket. Details longer than
4000 characters are truncated rather than raising.
