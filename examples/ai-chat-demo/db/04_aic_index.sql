-- Step 4 of 7: make everything searchable and measure the cost. Run as the ADM schema owner.
-- Re-runnable: work that is done is not done again.
--
-- It does four things, in this order:
--   1. Extracts the text of the 10 files into the Oracle Text index. The bundled agent tools
--      (ADM_SEARCH_FILES, ADM_READ_FILE_CONTENT) read that index. Normally a job does this.
--   2. Refreshes the "shared with me" cache of both users. It holds the documents that reach a
--      user through a folder share; the accessible-documents listings read it. Normally the
--      first page load of the user does this.
--   3. Syncs the RAG collection aic_contracts (and aic_policies, if it exists already): finds the
--      files, extracts text, cuts chunks, calls the embedding model, stores the vectors. Normally
--      the five-minute job does this.
--   4. Prints what that cost: web service calls, request size, seconds, chunks.
--
-- Run with the sample set it makes one embedding call for each file (the chunks of a file go out in
-- batches of 10).

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

define aic_window_minutes = 2
set define on
set verify off
set serveroutput on
set feedback off
alter session set nls_numeric_characters = '.,';

declare
  l_start        timestamp := systimestamp;
  l_t0           timestamp;
  l_n            pls_integer := 0;

  function secs (p_from in timestamp) return varchar2 is
  begin
    return to_char(round(extract(second from (systimestamp - p_from))
                 + 60 * extract(minute from (systimestamp - p_from)), 1), 'FM990.0') || ' s';
  end secs;
begin
  adm_context_api.system_login;

  -- 1. text extraction for the Oracle Text index
  l_t0 := systimestamp;
  <<extract_loop>>
  for r in (
    select q.document_version_id
      from adm_indexing_queue q
      join adm_documents d on d.latest_version_id = q.document_version_id
      join adm_folders f on f.folder_id = d.folder_id
     where f.folder_path like '/groups/aic\_%' escape '\'
       and q.index_status = 'PENDING'
  ) loop
    adm_storage_index_api.process_document_indexing(r.document_version_id, null);
    l_n := l_n + 1;
  end loop extract_loop;
  commit;
  adm_storage_index_api.sync_text_index;
  sys.dbms_output.put_line('1. text index:   ' || l_n || ' file(s) extracted, index synced, ' || secs(l_t0));

  -- 2. the "shared with me" cache of both users
  l_t0 := systimestamp;
  adm_cache_api.update_subshared_files_cache('AIC_LEGAL');
  adm_cache_api.update_subshared_files_cache('AIC_HR');
  commit;
  sys.dbms_output.put_line('2. user caches:  AIC_LEGAL and AIC_HR refreshed, ' || secs(l_t0));

  -- 3. the RAG collections
  adm_context_api.system_login;   -- the cache calls above may have changed the context
  <<collection_loop>>
  for c in (
    select rag_collection_id, collection_name
      from adm_ai_rag_collections
     where collection_name in ('aic_contracts', 'aic_policies')
     order by collection_name
  ) loop
    l_t0 := systimestamp;
    adm_ai_rag_workflow_api.rag_collection_maintenance(p_collection_id => c.rag_collection_id);
    commit; -- @dblinter ignore(g-3310): this script is the caller, and a synced collection must stay committed if the next one fails
    sys.dbms_output.put_line('3. collection:   ' || rpad(c.collection_name, 14) || ' synced, ' || secs(l_t0));
  end loop collection_loop;

  sys.dbms_output.put_line('   total:        ' || secs(l_start));
  -- the system user only for this block: the next statement in this session runs as nobody
  adm_context_api.clear_context;
exception
  when others then
    adm_context_api.clear_context;
    raise;
end;
/

prompt
prompt Embedding calls of the last &aic_window_minutes. minutes (apex_webservice_log). One call per file: the chunks of a file go
prompt out in batches of 10. Another embedding call in the window, for example from 00_precheck.sql, is counted too. Calls to the chat model are left out on purpose, because anything else
prompt that uses the same web credential in these minutes would be counted too.
col url        format a40
col calls      format 999
col req_bytes  format 999,999
col seconds    format 999.9
select url
     , count(*)                  as calls
     , sum(content_length)       as req_bytes
     , round(sum(elapsed_sec), 1) as seconds
  from apex_webservice_log
 where url like '%openai.com/v1/embeddings'
   and request_date >= sysdate - 1 / 24 / 60 * &aic_window_minutes.
 group by url
 order by url;

set define off
prompt
prompt Per file (file_status must be INDEXED for every file you expect to find):
col collection_name format a14
col document_name   format a36
col file_status     format a10
select collection_name
     , document_name
     , file_status
     , chunk_count
     , embedded_chunk_count
  from adm_ai_rag_collection_files_v
 where collection_name in ('aic_contracts', 'aic_policies')
   and is_active = 'Y'
 order by collection_name, document_name;
set feedback on
