---
name: adm-ai-rag
description: >
  Retrieval-augmented generation over ADM documents with the APEX Document Management AI Pack
  (adm_ai_rag_api, adm_ai_rag_workflow_api): create and update a RAG collection from a config JSON,
  search_chunks, prepare_sources, generate_answer, and the sync, extract, chunk and embed pipeline.
  Use for "ask questions of my documents", vector search, embeddings, chunks, Qdrant or Oracle AI
  Vector Search in ADM. Needs the AI Pack. Not for full-text search (adm-search-and-tags).
metadata:
  version: "26.2"
---

# RAG over ADM documents (AI Pack)

The AI Pack is installed separately (`install_ai.sql`) and needs `uc_ai` and an APEX web credential for
your LLM provider. If `adm_ai_rag_api` does not exist, say so. Context and transaction rules: see
`adm-plsql`. Errors come from `adm_ai_error` (`-20600 .. -20699`).

A **RAG collection** is the set of ADM documents that match its source (a folder subtree or an annotation
key), kept chunked and embedded in a vector store by a scheduled job. A document uploaded a moment ago
is not yet answerable.

## Gotchas

1. **Collection calls are ADMIN-only** (`e_admin_required`). With `"vector_store": "ORACLE"`, create and
   delete run DDL (create or drop the store table), which **commits your transaction**: a later rollback
   does not undo the collection row. Run them alone, under `system_login`.
2. **The name is lowercased, then checked against `^[a-z0-9_-]+$`.** `Case_Files` is stored as
   `case_files`; a space or any other character raises `e_config_invalid`.
3. **Required config:** `source_folder_path` or `source_file_annotation_key`, `content_type` (`"text"`),
   `embedding` (`dimensions`, `provider`, `model`). Give `chunks` with all four sizes as well: the
   validator accepts a missing one and falls back to built-in sizes. Never put an API key in the JSON:
   `config.g_apex_web_credential` names the APEX web credential.
4. **`update_rag_collection` replaces the whole config.** A non-null `p_config_json` is not merged:
   only `vector_store`, `vector_index` and the four `default_*` keys are carried over when omitted.
   Leave out `embedding` and it raises `e_config_missing`; leave out `chunks`, `answer_model` or
   `query_rewriting` and it is dropped. Read the stored `config_json`, change it, pass it back whole.
   `embedding.dimensions` cannot change once the store exists (`e_vector_dims_immutable`).
   `p_collection_name` and `p_description` change on their own.
5. **`vector_store` defaults to `ORACLE` on 23ai and later, `QDRANT` below** (a legacy collection
   without the key is `QDRANT`). `ORACLE` on 19c raises `e_no_vector_support`. If the vector index is
   missing, searches fall back to an exact scan without a message: check
   `adm_ai_vector_api.get_store_status(p_rag_collection_id)` (`index_status`, `last_error`).
6. **Only text-like files join:** `text/*`, PDF, Office and OpenDocument, JSON, XML, e-mail, and
   `application/octet-stream`. Images and other binaries never do. Trashed documents are out;
   archived ones are filtered at search time. A collection takes `llm_text_extraction` **or**
   `ocr_text_extraction`, not both.
7. **`rag_collection_maintenance` runs sync itself,** then every stage, with embedding and LLM HTTP calls
   inline, holding the collection row lock until you commit. Each stage handles at most
   `AI_CHUNK_FILE_LIMIT` files per call, so one call may not finish the work. Do not call
   `sync_rag_collection_files` first. A sync that finds another one running skips silently.
8. **Retrieval applies the caller's rights after the top-k cut.** `search_chunks` can return fewer rows
   than `p_limit`. `system_login` matches everything: use `system_user_login` for a person. An ADMIN
   person gets the personal view; `p_as_admin => true` (all four retrieval calls) opts in to every
   document. `generate_answer` says `No relevant sources found to answer this question.` for no match.
9. **`p_document_id` exists on `search_chunks` and `prepare_sources` only.** It needs `ORACLE`
    (`e_no_doc_scoped_search`, raised before the embedding call); a document not active in the collection
    gives no rows. `p_rewrite_config` and `p_answer_config` are `json_object_t`, merged
    over the config (your keys win). `generate_answer_debug` is a **procedure**
    (`po_answer`, `po_debug_log_id`).
10. **Query rewriting is an extra LLM call.** `p_rewrite_query => true` needs provider and model from the
    config's `query_rewriting` or from `p_rewrite_provider` / `p_rewrite_model` (else `e_config_missing`).
    With `query_rewriting.enabled: true` in the config, every search rewrites unless you pass `false`.
11. **Defaults:** argument, then the collection's `default_*`, then threshold 0.5, limit 20, 5 sources, 1
    surrounding chunk. A good threshold depends on the embedding model: lower it if a filled collection
    finds nothing. With `hybrid_search`, `score` is an RRF score, not a cosine similarity.

## Recipes

### Create a collection

```sql
declare
  l_collection_id adm_ai_rag_collections.rag_collection_id%type;
  l_config        clob;
begin
  adm_context_api.system_login;

  l_config := q'~{
    "source_folder_path": "/cases",
    "content_type": "text",
    "vector_store": "ORACLE",
    "default_score_threshold": 0.5,
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

`"source_file_annotation_key"` instead takes any document or folder carrying that annotation
(`adm_annotations_api.add_document_annotation`). Field reference (`query_rewriting`,
`llm_text_extraction`, `ocr_text_extraction`, `hybrid_search`, `vector_index`):
<https://united-codes.com/products/apex-document-management/docs/ai-pack-guides/rag_configurations/>

Change a setting: read the stored config, edit it, pass all of it back (gotcha 4).

```sql
select config_json into l_config from adm_ai_rag_collections where rag_collection_id = l_collection_id;
l_obj := json_object_t.parse(l_config);                     -- l_obj json_object_t
l_obj.put('default_score_threshold', 0.4);
adm_ai_rag_api.update_rag_collection(p_rag_collection_id => l_collection_id, p_config_json => l_obj.to_clob);
```

`delete_rag_collection` takes `p_rag_collection_id` or `p_collection_name`.

### Ask a question

```sql
select rag_chunk_id, document_id, document_name, chunk_index, score, chunk_text   -- also version_id, version_number
  from table(adm_ai_rag_api.search_chunks(
         p_rag_collection_id => l_collection_id
       , p_query             => 'what did we agree about liability'
       , p_limit             => null         -- null: collection default
       ))
 order by score desc;

select document_id, document_name, chunk_count, avg_score, source_text   -- one row per document
  from table(adm_ai_rag_api.prepare_sources(
         p_rag_collection_id => l_collection_id
       , p_query             => :P1_QUESTION
       , p_surrounding_chunks => 1           -- neighbours merged into prose; gaps marked [...]
       ));

l_answer := adm_ai_rag_api.generate_answer(   -- clob; per-call p_answer_provider / p_answer_model
  p_rag_collection_id => l_collection_id
, p_query             => :P1_QUESTION
);

adm_ai_rag_api.generate_answer_debug(p_rag_collection_id => l_collection_id, p_query => :P1_QUESTION
, po_answer => l_answer, po_debug_log_id => l_log_id);   -- then get_debug_log_markdown(p_debug_log_id => l_log_id)
```

### Check progress, or force the pipeline

```sql
select collection_status, active_file_count, searchable_file_count, failed_file_count   -- ERROR, PROCESSING, PENDING, INCOMPLETE, EMPTY, READY
  from adm_ai_rag_collection_status_v
 where rag_collection_id = :id;

select adm_ai_rag_workflow_api.pending_work_count(p_stage => 'EMBEDDING', p_collection_id => :id)
  from dual;
```

Stages: `LOCAL_EXTRACTION`, `TEXT_EXTRACTION`, `CHUNKING`, `EMBEDDING`, `REMOVE` (also `QDRANT_CLEANUP`,
`OCR_FALLBACK`). In SQL pass the string: a package constant (`c_stage_embedding`) is not allowed there.
Always pass the collection for `LOCAL_EXTRACTION` and `CHUNKING`. Only `TEXT_EXTRACTION`, `EMBEDDING` and
`REMOVE` have rows in `adm_ai_rag_job_queue`; the others follow file state. The count honours the retry
budget, so a failing file stops being pending. To force a run, call
`rag_collection_maintenance(p_collection_id => l_id)` and `commit`, again until every stage you use
reports 0 (cap the loop). Single stages: `process_collection_text_extraction`,
`process_text_extraction_jobs`, `process_collection_chunks`, `process_embedding_jobs`,
`process_remove_jobs` (each takes `p_limit`).

## Errors

| Exception | Raised when |
| --- | --- |
| `e_collection_not_found` | unknown id or name in any collection call or `search_chunks` |
| `e_config_not_json`, `e_config_missing`, `e_config_invalid` | config is not JSON; a required key is absent; bad value, bad name, `llm` plus `ocr` |
| `e_chunk_config`, `e_unsupported_value` | chunk sizes contradict each other; `content_type`, `vector_store` or `distance_metric` not allowed (also an unknown `p_stage`) |
| `e_no_vector_support`, `e_vector_dims_immutable`, `e_no_doc_scoped_search` | gotchas 4, 5 and 9 |
| `e_admin_required` | create, update or delete without an ADMIN context |

`e_embedding` and `e_generation` exist, but the AI Pack never raises them: do not expect them for a provider failure.
Anything else: the API reference, or
`select argument_name, data_type, in_out, defaults from user_arguments where package_name = 'ADM_AI_RAG_API' and object_name = 'SEARCH_CHUNKS'`.
