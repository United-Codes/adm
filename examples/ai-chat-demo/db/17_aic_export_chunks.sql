-- Exports the text of every chunk of both collections to chunks.csv, so that
-- ../samples/count_tokens.py can count the embedding tokens exactly. Costs nothing.
--
--   sql -name <connection> @17_aic_export_chunks.sql
--   python3 ../samples/count_tokens.py chunks.csv        (needs: pip install tiktoken)
--
-- Why a script: uc_ai returns the vectors of an embedding call and nothing else, no usage figure.
-- text-embedding-3-small tokenizes with cl100k_base, so tiktoken gives the number OpenAI bills.

set define off
set sqlformat csv
set feedback off
set long 100000
set linesize 32767
set pagesize 0
spool chunks.csv
select c.collection_name
     , k.rag_chunk_id
     , k.chunk_index
     , k.chunk_length
     , replace(replace(dbms_lob.substr(v.index_content, k.chunk_length, k.chunk_start_pos), chr(10), '\n'), chr(13), '') as chunk_text
  from adm_ai_rag_chunks k
  join adm_ai_rag_collection_files cf on cf.rag_collection_file_id = k.rag_collection_file_id
  join adm_ai_rag_collections c on c.rag_collection_id = cf.rag_collection_id
  join adm_document_versions v on v.version_id = cf.version_id
 where c.collection_name like 'aic\_%' escape '\'
 order by 1, 2;
spool off
set sqlformat default
set feedback on
