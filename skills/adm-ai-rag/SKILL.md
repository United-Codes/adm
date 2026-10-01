---
name: adm-ai-rag
description: >
  Retrieval-augmented generation over ADM documents with the APEX Document Management AI Pack -
  adm_ai_rag_api: creating a RAG collection from a config JSON, search_chunks, prepare_sources
  and generate_answer, and how the sync/extract/chunk/embed pipeline runs off a job queue. Use
  whenever a task involves asking questions of ADM documents, vector search, embeddings, chunks,
  a RAG collection, Qdrant or Oracle AI Vector Search in ADM. Requires the AI Pack; read the
  adm-plsql skill first.
---

# RAG over ADM documents (AI Pack)

The AI Pack is installed **separately** from the ADM base product (`install_ai.sql`) and depends
on the `uc_ai` library and APEX web credentials for your LLM provider. If `adm_ai_rag_api` does
not exist in the schema, it is not installed — say so rather than working around it.

Needs an established context and your own `commit` — see `adm-plsql`. AI Pack errors come from
`adm_ai_error`, in the range `-20600 .. -20699`.

## The shape of it

A **RAG collection** is a subset of ADM documents, kept chunked and embedded. You define which
documents belong to it once; a pipeline then keeps it in step as files are uploaded, versioned and
removed:

```
adm_ai_rag_collection_files  →  text extraction  →  chunks  →  embeddings  →  vector store
        (sync)                                  (adm_ai_rag_job_queue)
```

Every stage runs **asynchronously**, off `adm_ai_rag_job_queue`, drained by a scheduled job. So a
document uploaded a moment ago is not yet answerable, and your code should not wait for it inline.

## Create a collection

```sql
declare
  l_collection_id number;
  l_config        clob;
begin
  adm_context_api.system_login;

  l_config := q'~{
    "source_folder_path": "/cases",
    "content_type": "text",
    "vector_store": "ORACLE",
    "default_limit": 20,
    "default_score_threshold": 0.5,
    "default_max_sources": 5,
    "default_surrounding_chunks": 1,
    "embedding": {
      "dimensions": 1536,
      "provider": "openai",
      "model": "text-embedding-3-small",
      "config": { "g_apex_web_credential": "OPENAI_API_KEY" }
    },
    "chunks": {
      "target_chunk_size": 2048,
      "overlap_size": 256,
      "min_chunk_size": 512,
      "max_chunk_size": 2560
    },
    "answer_model": {
      "provider": "openai",
      "model": "gpt-4o",
      "system_prompt": "Answer using only the provided sources, and cite them.",
      "config": { "g_apex_web_credential": "OPENAI_API_KEY" }
    }
  }~';

  l_collection_id := adm_ai_rag_api.create_rag_collection(
    p_collection_name => 'case_files'
  , p_description     => 'Everything under /cases'
  , p_config_json     => l_config
  );

  commit;
end;
/
```

Rules that will bite otherwise:

- **The collection name must match `^[a-z0-9_-]+$`** — lowercase letters, digits, underscore,
  hyphen. No spaces, no capitals. A database constraint enforces it, and a name that predates the
  constraint makes *every* later update of that collection fail.
- **Required config sections:** `source_folder_path` **or** `source_file_annotation_key`,
  plus `content_type` (`"text"`), `embedding` and `chunks`. Everything else is optional.
- `source_folder_path` takes the folder and everything below it. `source_file_annotation_key`
  takes any document carrying that annotation — or in a folder carrying it — which is how you
  build a collection that is not a subtree (set the annotation with
  `adm_annotations_api.add_document_annotation`).
- `vector_store` is `"ORACLE"` (native Oracle AI Vector Search, 23ai and later — nothing external
  to run) or `"QDRANT"` (external Qdrant, for databases without native vector support). Legacy
  collections default to `QDRANT`.
- The `config` object inside each AI section is passed straight through to `uc_ai`;
  `g_apex_web_credential` names the APEX web credential holding the API key. **Do not put an API
  key in the JSON.**
- Changing the config later is `adm_ai_rag_api.update_rag_collection(p_rag_collection_id => ...)`;
  every argument is optional, so pass only what changes.
- `adm_ai_rag_api.delete_rag_collection` takes either an id or a name.

Full field reference, including `query_rewriting`, `llm_text_extraction` and `hybrid_search`:
<https://united-codes.com/products/apex-document-management/docs/ai-pack-guides/rag_configurations/>

## Ask a question

Three entry points, in increasing order of how much they do for you.

**`search_chunks`** — the matching passages, pipelined:

```sql
select rag_chunk_id, document_id, document_name, chunk_index, score, chunk_text
  from table(adm_ai_rag_api.search_chunks(
         p_rag_collection_id => l_collection_id
       , p_query             => 'what did we agree about liability'
       , p_limit             => 20            -- null uses the collection's default_limit
       , p_score_threshold   => 0.5           -- null uses default_score_threshold
       ))
 order by score desc;
```

**`prepare_sources`** — the same matches grouped per document, ranked by their best chunk, each
expanded by `p_surrounding_chunks` neighbours on both sides. Overlapping ranges are merged, and
non-contiguous passages are separated by a `[...]` marker, so `source_text` reads as prose rather
than as fragments:

```sql
select document_id, document_name, chunk_count, avg_score, source_text
  from table(adm_ai_rag_api.prepare_sources(
         p_rag_collection_id => l_collection_id
       , p_query             => :P1_QUESTION
       , p_max_sources       => 5
       ));
```

**`generate_answer`** — retrieval plus an LLM answer, returned as a `clob`:

```sql
l_answer := adm_ai_rag_api.generate_answer(
  p_rag_collection_id => l_collection_id
, p_query             => :P1_QUESTION
, p_system_prompt     => null      -- null uses answer_model.system_prompt from the config
);
```

Every parameter that tunes retrieval (`p_limit`, `p_score_threshold`, `p_max_sources`,
`p_surrounding_chunks`) defaults to the collection's `default_*` setting when left null — put the
policy in the config and pass nothing.

You can override the provider and model per call — `p_answer_provider`, `p_answer_model`,
`p_answer_config`, and the `p_rewrite_*` equivalents. A `p_*_config` you pass is **merged over**
the collection's config, with your keys winning.

`p_rewrite_query => true` sends the question to an LLM to be rewritten before searching, which
helps for conversational phrasing. It costs a round trip, and needs `query_rewriting` in the
config.

Restricting a search to one document:

```sql
... p_document_id => 4711 ...
```

That needs the **native Oracle vector store** — Qdrant points carry no payload to filter on, so a
`QDRANT` collection raises `adm_ai_error.e_no_doc_scoped_search` rather than quietly searching
everything.

`generate_answer_debug` returns the answer plus a debug log id, and
`get_debug_log_markdown(p_debug_log_id)` renders what was retrieved and sent as markdown. That is
the tool for "why did it answer that".

## Permissions still apply

`search_chunks` filters its results through `adm_access_control_api.user_is_allowed_to_view_document`
for the calling context, so a user never gets a passage out of a document they may not open. Two
consequences:

- Under `adm_context_api.system_login` **everything matches**, because an admin context bypasses the
  check. Use `system_user_login` when the answer is going to a specific person.
- Retrieval is not a way around ADM's permissions, so a collection over `/cases` can safely back a
  page used by several users with different access.

## Keeping a collection current

The pipeline is driven by the queue and a scheduled job; in normal operation you do not call it.
When you need to force a collection forward — a migration, a test, an import that must be
answerable now — the workflow API exposes each stage:

```sql
begin
  adm_context_api.system_login;

  adm_ai_rag_workflow_api.sync_rag_collection_files(p_collection_id => l_id);  -- membership
  adm_ai_rag_workflow_api.rag_collection_maintenance(p_collection_id => l_id); -- run the stages
  commit;
end;
/
```

`sync_rag_collection_files` reconciles membership: new matching documents are added, documents with
a new version are pointed at it, and documents that no longer match are marked inactive (their
vectors are cleaned up later by a `REMOVE` job — searches ignore inactive files immediately).

To see whether anything is waiting:

```sql
select adm_ai_rag_workflow_api.pending_work_count(
         p_stage         => adm_ai_rag_workflow_api.c_stage_embedding
       , p_collection_id => l_id
       ) as pending_embeddings
  from dual;
```

The stages are `c_stage_local_extraction`, `c_stage_llm_extraction`, `c_stage_chunking`,
`c_stage_embedding` and `c_stage_remove`. `pending_work_count` is the right thing to put on a
monitoring page — it uses the same definition of "eligible" as the pipeline itself, including the
retry budget, so a permanently failing file stops being counted rather than showing as forever
pending.

Text extraction quality is usually what limits answer quality, not the model. For scanned or messy
PDFs, configure `llm_text_extraction` to run the file through a multimodal model instead of the
built-in filter — it is per collection and can be narrowed to specific mime types.
