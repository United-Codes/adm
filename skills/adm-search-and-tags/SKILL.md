---
name: adm-search-and-tags
description: >
  Tagging and finding documents in APEX Document Management (ADM) from PL/SQL - adm_tag_api for
  key/value tags, and adm_search_api for full-text and faceted search (search_documents,
  search_user_documents, create_tag_facet, create_tag_value_facet, combine_facets). Use
  whenever a task involves tagging an ADM document, a taxonomy, searching document content,
  filtering documents by tag or tag value, or building a search page or REST endpoint over ADM.
  Read the adm-plsql skill first.
---

# Tags and search

Needs an established context and your own `commit` for anything that writes — see `adm-plsql`.

A **tag** (`adm_tags`) is a name; attaching it to a document (`adm_document_tags`) may carry a
**value**, which is what makes a taxonomy: `department = finance`, `year = 2026`. Tag names are
**lowercased** on creation, so `Department` and `department` are one tag.

## Tagging

`create_tag` is get-or-create — it returns the existing id when the name is already known:

```sql
l_tag_id := adm_tag_api.create_tag(p_tag_name => 'department');
```

Most of the time you do not need the id, because attaching by name creates the tag if it is
missing:

```sql
adm_tag_api.add_tag_to_document(
  p_document_id => 4711
, p_tag_name    => 'department'
, p_tag_value   => 'finance'      -- optional; null tags the document without a value
);
```

`add_tag_to_document` is **idempotent**: attaching a tag the document already carries replaces its
value rather than leaving a second assignment behind. That makes it the right call in a re-runnable
import — no "does it already have this tag" check needed. (Two sessions doing it at the very same
instant can still both insert; `adm_document_tags` has no unique key.)

Changing and removing:

```sql
adm_tag_api.update_document_tag_value(p_document_id => 4711, p_tag_name => 'department', p_tag_value => 'legal');
adm_tag_api.remove_document_tag(p_document_id => 4711, p_tag_name => 'department');
adm_tag_api.remove_all_tags_from_document(p_document_id => 4711);
```

`update_document_tag_value` by **name** raises `adm_error.e_tag_ambiguous` if the document happens
to carry that tag twice — possible in a database filled before tagging became idempotent. Handle
those through the `document_tag_id` overloads, which address one assignment exactly:

```sql
adm_tag_api.update_document_tag_value(p_document_tag_id => l_dt_id, p_tag_value => 'legal');
adm_tag_api.remove_document_tag(p_document_tag_id => l_dt_id);
```

`create_document_tag(p_document_id, p_tag_id, p_tag_value)` returns a new `document_tag_id` when
you need one to hold on to.

Read tags back with SQL — `adm_document_tags` joined to `adm_tags`, or `adm_report_tags_v` for
usage statistics. For metadata that is **not** meant to be a user-facing tag, use annotations
instead (see `adm-documents`).

## Searching

`adm_search_api` returns a pipelined table you select from:

```sql
select *
  from table(adm_search_api.search_documents(
         p_search_expression => 'quarterly report'
       , p_modified_after    => systimestamp - 30
       ));
```

Each row carries `document_id`, `document_name`, `created_by`, `folder_id`, `folder_path`,
`latest_version_id`, `user_owner`, `group_owner` and `score` (Oracle Text relevance).

Two functions, and the difference matters:

| Function | Returns |
| --- | --- |
| `search_documents` | Every matching document in the instance — **no permission filter**. For an admin report, or inside code that filters afterwards. |
| `search_user_documents(p_username => ...)` | Only what that user may see. This is the one to put behind a user-facing page. |

```sql
select *
  from table(adm_search_api.search_user_documents(
         p_username          => sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username)
       , p_search_expression => 'quarterly report'
       ));
```

`search_user_documents` reads a **cached** list of files shared with the user. The cache is
refreshed nightly and while the user is active in the app, so a share granted seconds ago may not
be reflected yet. Force it when your workflow grants access and searches in the same breath:

```sql
adm_cache_api.update_subshared_files_cache(p_username => 'JDOE');
```

`p_search_expression` is an Oracle Text expression, so `and`, `or`, `%` and `?` work — and a
user's raw input containing those characters can therefore fail the parse. Sanitize or wrap
untrusted input before passing it.

**Newly uploaded content is not instantly searchable by its text.** Content matching runs against
the Oracle Text indexes on `adm_document_versions` (`contains`), and for object-storage documents
against text that a background extraction queue has to fetch and store first. Neither is in place
the instant `create_document` returns, so a create-then-search in one script finds nothing by
content. Names, tags, annotations and every other column are queryable at once.

## Facets: filtering by tag

Facets are passed as one string. Build it with the helpers rather than by hand:

```sql
declare
  l_facets varchar2(4000 char);
begin
  l_facets := adm_search_api.combine_facets(
    apex_t_varchar2(
      adm_search_api.create_tag_facet(p_tag_id => 456)                              -- has the tag, any value
    , adm_search_api.create_tag_value_facet(p_tag_id => 123, p_tag_value => 'finance')  -- has the tag with this value
    )
  );

  for r in (
    select *
      from table(adm_search_api.search_user_documents(
             p_username        => 'JDOE'
           , p_dyn_facets      => l_facets
           , p_facet_and_match => 'Y'      -- 'Y' = all facets must match, 'N' (default) = any
           ))
  ) loop
    ...
  end loop;
end;
/
```

- `create_tag_facet` produces `G#tag_id` — the document carries the tag, whatever its value.
- `create_tag_value_facet` produces `I#tag_id#tag_value` — the tag with that exact value.
- `combine_facets` joins them with colons. Do not concatenate the strings yourself.
- Facets take **`tag_id`, not the tag name.** `adm_tag_api.create_tag(p_tag_name => 'department')`
  returns the id for a name you know.
- `p_facet_and_match => 'Y'` is AND, `'N'` is OR. The default is `'N'`, which is rarely what a
  filter panel means — set it explicitly.
- One limitation to be aware of: a tag **value** that itself contains the sequence `:G#` or `:I#`
  cannot be represented in a facet string.

Both search functions take facets, a search expression and `p_modified_after`, and all of them are
optional — facets alone give you "every document tagged like this", with no full-text term at all.
