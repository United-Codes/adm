---
name: adm-search-and-tags
description: >
  Tagging documents and finding them in APEX Document Management (ADM) from PL/SQL: adm_tag_api
  (key/value tags) and adm_search_api (search_documents, search_user_documents, create_tag_facet,
  create_tag_value_facet, combine_facets). Use for tagging a document, a taxonomy, "find documents
  containing a word", "find documents by tag value", or a search page or REST endpoint over ADM.
  Not for listing or reporting with plain SQL (see adm-querying) and not for who may see what (see
  adm-sharing-and-permissions).
metadata:
  version: "26.2"
---

# Tags and search

A tag (`adm_tags`) is a name. Attached to a document (`adm_document_tags`) it can carry a value:
`department = Finance`. For contexts and your own `commit`, see `adm-plsql`.

## Gotchas

1. **`p_search_expression` is plain words, not an Oracle Text expression.** ADM cuts the input into
   alphanumeric words (2 characters or more, at most 50) and finds documents that contain any of them,
   best score first. `and`, `or`, `%`, `?`, quotes and braces do nothing: `and` is searched as a
   word. Raw user input is safe: it cannot cause a parse error. There is no way to ask for a phrase
   or for "all words".
2. **The whole trimmed term is also matched against the document name**, as a case-insensitive
   substring. A name-only hit has score 1. A one-letter term finds every document whose name
   contains that letter.
3. **Content is searchable late.** The name and the tags work at once. The text of a file is
   extracted by the job `ADM_INDEXING_JOB` (every 5 minutes), and only after the upload is
   committed. A create-then-search in one script or one transaction finds nothing by content.
   Only the latest version is searched. Only file types that carry text are extracted
   (images, video and archives are not), and a file in object storage only when the setting
   `OBJECT_STORAGE_INDEX` is `Y`. To catch up now, call `adm_job_automations_api.indexing_job` as an
   administrator (recipe 4).
4. **`search_documents` has no permission filter.** It returns every match in the instance. Behind
   a user-facing page use `search_user_documents`. Both skip trashed and archived documents and
   documents in a trashed folder.
5. **`search_user_documents` needs `p_username`** (null raises `e_missing_param`; case does not
   matter; an unknown name finds nothing). Search is personal: an `ADMIN` user finds only what they own
   or what was shared with them, like everyone else. Only the system user finds every active document:
   under `system_login` pass `sys_context('ADM_CONTEXT', 'ADM_USERNAME')` (it is not in
   `adm_users`). Passing `_UC_SYSTEM_` from another session finds nothing. The access
   list comes from a cache: a share on a **folder** appears only after
   `adm_cache_api.update_subshared_files_cache(p_username => ...)` or the next cache refresh (nightly,
   and while the user is active in an ADM application). Shares on one document, own folders and group
   folders count at once, and a revoked share stops working at once. For no delay, use `adm_my_documents_v` (see `adm-querying`).
6. **You need an expression or facets.** With neither, the result is empty. `p_modified_after` only
   narrows: alone it returns nothing. An expression and facets must both match.
7. **Facets use `tag_id`, never the name.** Get it from `adm_tag_api.create_tag`. The value match is
   exact and case-sensitive (`finance` does not match `Finance`). A tag attached without a value
   cannot match a value facet: use `create_tag_facet`.
8. **`p_facet_and_match` accepts exactly `'Y'` (every facet) or `'N'` (any facet, the default).** Any
   other text, including `'y'`, returns nothing. A tag value that contains `:G#` or `:I#` cannot be
   searched.
9. **Tag names are trimmed and lower-cased** (a trigger enforces it); values keep their case. `create_tag`
   and `add_tag_to_document` create a tag that does not exist yet, but **only an administrator may** unless
   the setting `USERS_CAN_CREATE_TAGS` is `Y` (default `N`): then `e_no_permission`. Assigning an existing tag
   needs no such right, only EDIT on the document (`e_no_permission`); a trashed or unknown document raises
   `e_doc_not_found`.
10. **Writes are idempotent, deletes are not.** `add_tag_to_document` and `create_document_tag` on a
    document that has the tag replace its value (`create_document_tag` returns the existing id).
    `remove_document_tag` raises `e_tag_not_found` for an unknown tag and `e_tag_not_assigned` when the
    document does not carry it, so a re-run needs a handler.
11. **No row limit.** Results are ordered by score, then folder path. Page them yourself with
    `fetch first n rows only`.

## Recipes

**1. Find documents by tag value, end to end.**

```sql
declare
  l_tag_id   adm_tags.tag_id%type;
  l_facets   varchar2(4000 char);
  l_document adm_documents.document_id%type := 4711;   -- replace
begin
  adm_context_api.system_user_login(p_username => 'JDOE');

  l_tag_id := adm_tag_api.create_tag(p_tag_name => 'department');     -- get or create; you need the id for facets
  adm_tag_api.add_tag_to_document(
    p_document_id => l_document
  , p_tag_name    => 'department'
  , p_tag_value   => 'Finance'
  );

  l_facets := adm_search_api.combine_facets(
    apex_t_varchar2(adm_search_api.create_tag_value_facet(p_tag_id => l_tag_id, p_tag_value => 'Finance'))
  );

  for r in (
    select document_id, document_name, folder_path
      from table(adm_search_api.search_user_documents(
             p_username        => 'JDOE'
           , p_dyn_facets      => l_facets
           , p_facet_and_match => 'Y'))
  ) loop
    dbms_output.put_line(r.document_id || ' ' || r.folder_path || '/' || r.document_name);
  end loop;

  commit;
end;
/
```

Several facets: pass more elements to `combine_facets`. `create_tag_facet(p_tag_id => ...)` matches any
value. A user who may not see the document gets no row. Tags can be read with
`adm_my_document_tags_v` (visible documents) or `adm_report_tags_v` (usage counts, unfiltered).

**2. Search page for the logged-in user** (APEX report source; `:P1_SEARCH` is the search item). In a
script under `system_login` the same call finds every active document:

```sql
select s.document_id, s.document_name, s.folder_path, s.score
  from table(adm_search_api.search_user_documents(
         p_username          => sys_context('ADM_CONTEXT', 'ADM_USERNAME')
       , p_search_expression => :P1_SEARCH)) s
 order by s.score desc, s.document_name
 fetch first 20 rows only;
```

Text and tags together: add `p_dyn_facets` and `p_facet_and_match => 'Y'`.

**3. Tag import that can run twice.**

```sql
adm_tag_api.add_tag_to_document(p_document_id => l_document_id, p_tag_name => 'year', p_tag_value => '2026');
adm_tag_api.update_document_tag_value(p_document_id => l_document_id, p_tag_name => 'year', p_tag_value => '2027');
begin
  adm_tag_api.remove_document_tag(p_document_id => l_document_id, p_tag_name => 'year');
exception
  when adm_error.e_tag_not_assigned or adm_error.e_tag_not_found then null;
end;
adm_tag_api.remove_all_tags_from_document(p_document_id => l_document_id);   -- safe to repeat
```

Other calls: `update_document_tag(p_document_tag_id, p_tag_id, p_tag_value)` changes the tag and the
value of one assignment. If `update_document_tag_value` by name raises `e_tag_ambiguous` (a document that
got the same tag twice before tagging became idempotent), use the overloads that take `p_document_tag_id`.

**4. Make new content searchable now** (administrators only, so use `system_login` in a script; the call commits
and works for at most four minutes):

```sql
begin
  adm_context_api.system_login;
  adm_job_automations_api.indexing_job;
end;
/
select count(*) from adm_indexing_queue where index_status = 'PENDING';   -- repeat the call until 0
```

## Errors

| Exception | Raised when |
| --- | --- |
| `adm_error.e_missing_param` | `search_user_documents` with a null `p_username`; `create_tag` with a blank name |
| `adm_error.e_doc_not_found` | tagging a trashed or unknown document |
| `adm_error.e_no_permission` | tagging a document without EDIT rights; creating a new tag as non-admin while `USERS_CAN_CREATE_TAGS` is `N` |
| `adm_error.e_tag_not_found` | `remove_document_tag` or a `document_tag_id` call for an unknown tag |
| `adm_error.e_tag_not_assigned` | `remove_document_tag` or `update_document_tag_value` by name, tag not on the document |
| `adm_error.e_tag_ambiguous` | a by-name update of a tag that the document carries twice |
| `adm_error.e_tag_exists` | `update_document_tag` moves an assignment onto a tag the document already has |

Everything else: the generated reference at
<https://united-codes.com/products/apex-document-management/docs/api/adm_search_api/> and `adm_tag_api`. Parameters of a call:
`select argument_name, data_type, in_out, defaulted from user_arguments where package_name = 'ADM_X' and object_name = 'PROC'`.
