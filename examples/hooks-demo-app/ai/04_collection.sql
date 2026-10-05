-- Lesson 4 (optional): see a release at work in a RAG collection. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after 04_review.sql:
--
--   @04_collection.sql
--
-- It creates two collections that select their files by an annotation key: hkd_kb_invoice by
-- kb.invoice and hkd_kb_contract by kb.contract. It fills them, lists their files, accepts the
-- verdict of the supply agreement, and fills the contract collection again.
--
-- It needs Oracle 23ai for the native vector store, and the OPENAI credential for the embedding
-- model. It sends the text of the released invoices and of the accepted contract to the embedding
-- model: a few small requests. 99_hkd_ai_uninstall.sql deletes both collections.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column collection_name format a16
column document_name format a32
column file_status format a10
column chunk_count format 999
column files format 999

-- ---------------------------------------------------------------------------
-- Create two collections that select files by an annotation key
-- ---------------------------------------------------------------------------
declare
  c_config constant varchar2(2000 char) := q'[{
      "source_file_annotation_key": "@KEY@",
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
      }
    }]';

  procedure ensure_collection (
    p_name in varchar2
  , p_key  in varchar2
  )
  as
    l_exists number;
    l_id     number;
  begin
    select case when exists (
             select 1
               from adm_ai_rag_collections c
              where c.collection_name = p_name
           ) then 1 else 0 end
      into l_exists
      from dual;

    if l_exists = 0 then
      l_id := adm_ai_rag_api.create_rag_collection( -- @dblinter ignore(g-2135): the function returns the id, which this script does not need
        p_collection_name => p_name
      , p_description     => 'Course collection: the files with the annotation ' || p_key
      , p_config_json     => replace(c_config, '@KEY@', p_key)
      );
    end if;
  end ensure_collection;
begin
  adm_context_api.system_login;
  ensure_collection('hkd_kb_invoice', 'kb.invoice');
  ensure_collection('hkd_kb_contract', 'kb.contract');
  commit;
end;
/

-- ---------------------------------------------------------------------------
-- Fill both collections and list their files
-- ---------------------------------------------------------------------------
-- rag_collection_maintenance finds the files, extracts and chunks their text, and calls the
-- embedding model. The hourly job does this for you; the call skips the wait.
begin
  adm_context_api.system_login;
  <<collection_loop>>
  for r in (
    select c.rag_collection_id
      from adm_ai_rag_collections c
     where c.collection_name in ('hkd_kb_invoice', 'hkd_kb_contract')
  ) loop
    adm_ai_rag_workflow_api.rag_collection_maintenance(p_collection_id => r.rag_collection_id);
  end loop collection_loop;
  commit;
end;
/

select c.collection_name
     , count(f.rag_collection_file_id) as files
  from adm_ai_rag_collections c
  left join adm_ai_rag_collection_files_v f
    on f.rag_collection_id = c.rag_collection_id
 where c.collection_name in ('hkd_kb_invoice', 'hkd_kb_contract')
 group by c.collection_name
 order by c.collection_name;

select f.collection_name
     , f.document_name
     , f.file_status
     , f.chunk_count
  from adm_ai_rag_collection_files_v f
 where f.collection_name in ('hkd_kb_invoice', 'hkd_kb_contract')
 order by f.collection_name
        , f.document_name;

-- ---------------------------------------------------------------------------
-- Accept the contract and fill the collection again
-- ---------------------------------------------------------------------------
-- The contract collection is empty: the type contract needs review, so no verdict has released a
-- contract. A reviewer accepts the verdict of the supply agreement, and the annotation
-- kb.contract appears.
declare
  l_result_id hkd_ai_results.result_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  select v.result_id
    into l_result_id
    from hkd_ai_latest_v v
   where v.document_name = 'supply_agreement_ferrotek.pdf';
  hkd_ai_api.accept(l_result_id);
  commit;
end;
/

declare
  l_collection_id adm_ai_rag_collections.rag_collection_id%type;
begin
  adm_context_api.system_login;
  select c.rag_collection_id
    into l_collection_id
    from adm_ai_rag_collections c
   where c.collection_name = 'hkd_kb_contract';
  adm_ai_rag_workflow_api.rag_collection_maintenance(p_collection_id => l_collection_id);
  commit;
end;
/

select c.collection_name
     , count(f.rag_collection_file_id) as files
  from adm_ai_rag_collections c
  left join adm_ai_rag_collection_files_v f
    on f.rag_collection_id = c.rag_collection_id
 where c.collection_name in ('hkd_kb_invoice', 'hkd_kb_contract')
 group by c.collection_name
 order by c.collection_name;

select f.collection_name
     , f.document_name
     , f.file_status
     , f.chunk_count
  from adm_ai_rag_collection_files_v f
 where f.collection_name = 'hkd_kb_contract'
 order by f.document_name;
