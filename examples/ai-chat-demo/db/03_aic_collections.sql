-- Step 3 of 7: two RAG collections, one per folder. Run as the ADM schema owner, after step 2.
-- Re-runnable: a collection that exists is left alone (drop it with 99_aic_teardown.sql).
--
--   aic_contracts  reads /groups/aic_legal   (the contracts)
--   aic_policies   reads /groups/aic_hr      (the policies)
--
-- This is the smallest configuration that works for questions and answers:
--   * source_folder_path   which files belong to the collection
--   * embedding            OpenAI text-embedding-3-small (1536 dimensions) with the web credential OPENAI
--   * chunks               small chunks, because every sample file is only one or two pages
--   * answer_model         the model that generate_answer calls
--   * vector_store ORACLE  native Oracle AI Vector Search; nothing else to install
--   * llm_text_extraction  contracts only, and only for files annotated aic.scan = Y
-- Creating a collection only stores the configuration. Nothing is embedded until step 4.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

declare
  procedure ensure_collection (
    p_name        in varchar2
  , p_description in varchar2
  , p_folder_path in varchar2
  , p_scan_extraction in boolean default false
  )
  as
    l_exists number;
    l_id     number;
    l_config clob;
    l_scan   varchar2(1000 char);
  begin
    select case when exists (select 1 from adm_ai_rag_collections c where c.collection_name = p_name) then 1 else 0 end
      into l_exists
      from dual;
    if l_exists > 0 then
      sys.dbms_output.put_line('  collection exists:  ' || p_name);
      return;
    end if;

    -- Only for the contracts: files with the annotation aic.scan = Y are read by a model, because
    -- a scanned PDF has no text layer.
    if p_scan_extraction then
      l_scan := ', "llm_text_extraction": {
        "provider": "openai",
        "model": "gpt-6.1-sol",
        "apply_to": { "mime_types": ["application/pdf"], "annotation_key": "aic.scan", "annotation_value": "Y" },
        "config": { "g_apex_web_credential": "OPENAI" }
      }';
    end if;

    l_config := '{
      "source_folder_path": "' || p_folder_path || '",
      "content_type": "text",
      "vector_store": "ORACLE",
      "distance_metric": "Cosine",
      "embedding": {
        "dimensions": 1536,
        "provider": "openai",
        "model": "text-embedding-3-small",
        "config": { "g_apex_web_credential": "OPENAI" }
      },
      "chunks": {
        "target_chunk_size": 700,
        "overlap_size": 100,
        "min_chunk_size": 200,
        "max_chunk_size": 900
      },
      "answer_model": {
        "provider": "openai",
        "model": "gpt-6.1-sol",
        "config": { "g_apex_web_credential": "OPENAI" }
      }' || l_scan || '
    }';

    l_id := adm_ai_rag_api.create_rag_collection(
      p_collection_name => p_name
    , p_description     => p_description
    , p_config_json     => l_config
    );
    sys.dbms_output.put_line('  collection created: ' || p_name || ' (id ' || l_id || ')');
  end ensure_collection;
begin
  adm_context_api.system_login;

  ensure_collection('aic_contracts', 'Demo: the contracts of the Legal group', '/groups/aic_legal', p_scan_extraction => true);
  ensure_collection('aic_policies',  'Demo: the policies of the HR group',     '/groups/aic_hr');
  commit;
end;
/
set feedback on
