-- Lesson 1, the SQL alternative to the RAG collection manager: creates the collection aic_policies
-- over /groups/aic_hr and indexes it. Run as the ADM schema owner, after install.sql:
--
--   sql -name <connection> @03b_aic_policies.sql
--
-- Lesson 1 creates this collection in the RAG collection manager. This script passes the same
-- configuration that the form builds (its Advanced (JSON) tab) to adm_ai_rag_api.create_rag_collection.
-- Use one of the two ways, not both. Re-runnable: a collection that exists is left alone, and the
-- indexing step does only the work that is still open. 99_aic_teardown.sql deletes the collection.
--
-- Costs one embedding call for each of the 5 policy files, about 850 tokens.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

-- ---------------------------------------------------------------------------
-- Create the collection
-- ---------------------------------------------------------------------------
declare
  c_name   constant adm_ai_rag_collections.collection_name%type := 'aic_policies';
  l_exists number;
  l_id     adm_ai_rag_collections.rag_collection_id%type;
begin
  adm_context_api.system_login;

  select case when exists (select 1 from adm_ai_rag_collections c where c.collection_name = c_name) then 1 else 0 end
    into l_exists
    from dual;

  if l_exists > 0 then
    sys.dbms_output.put_line('collection exists:  ' || c_name);
  else
    l_id := adm_ai_rag_api.create_rag_collection(
      p_collection_name => c_name
    , p_description     => 'Demo: the policies of the HR group'
    , p_config_json     => '{
        "source_folder_path": "/groups/aic_hr",
        "content_type": "text",
        "distance_metric": "Cosine",
        "vector_store": "ORACLE",
        "embedding": {
          "provider": "openai",
          "model": "text-embedding-3-small",
          "config": { "g_apex_web_credential": "OPENAI" },
          "dimensions": 1536
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
        }
      }'
    );
    sys.dbms_output.put_line('collection created: ' || c_name || ' (id ' || l_id || ')');
  end if;
  commit;
  -- the system user only for this block: the next statement in this session runs as nobody
  adm_context_api.clear_context;
exception
  when others then
    adm_context_api.clear_context;
    raise;
end;
/

-- ---------------------------------------------------------------------------
-- Index the collection
-- ---------------------------------------------------------------------------
-- The same work as "Index now" in the RAG collection manager, but in this session: find the files,
-- extract their text, cut chunks, call the embedding model, store the vectors.
declare
  l_id adm_ai_rag_collections.rag_collection_id%type;
begin
  adm_context_api.system_login;
  select rag_collection_id into l_id from adm_ai_rag_collections where collection_name = 'aic_policies';
  adm_ai_rag_workflow_api.rag_collection_maintenance(p_collection_id => l_id);
  commit;
  sys.dbms_output.put_line('collection indexed: aic_policies');
  -- the system user only for this block: the next statement in this session runs as nobody
  adm_context_api.clear_context;
exception
  when others then
    adm_context_api.clear_context;
    raise;
end;
/

prompt
prompt Per file (file_status must be INDEXED for all 5 files):
set linesize 200
col collection_name format a14
col document_name   format a36
col file_status     format a10
select collection_name
     , document_name
     , file_status
     , chunk_count
     , embedded_chunk_count
  from adm_ai_rag_collection_files_v
 where collection_name = 'aic_policies'
   and is_active = 'Y'
 order by document_name;
set feedback on
