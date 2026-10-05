-- Lesson 1: read what the classifier did with the invoice. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after 00_load_pdfs.sql and wait.sql:
--
--   @01_read_result.sql
--
-- Reads data only. It makes no model call.

set serveroutput on
set feedback off
set linesize 200
column workflow_code format a20
column status format a8
column summary format a80
column tag_name format a13
column tag_value format a10
column annotation_key format a14
column annotation_value format a12
column doc_type format a10
column reason format a100

-- ---------------------------------------------------------------------------
-- Read the workflow runs of the file
-- ---------------------------------------------------------------------------
select w.workflow_code
     , w.status
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'inv_ferrotek_1042.pdf' and d.deleted_flag = 'N')
 order by w.run_id;

-- ---------------------------------------------------------------------------
-- Read the tag and the annotations in ADM
-- ---------------------------------------------------------------------------
select t.tag_name
     , dt.tag_value
  from adm_document_tags dt
  join adm_tags t
    on t.tag_id = dt.tag_id
 where dt.document_id = (select d.document_id from adm_documents d where d.document_name = 'inv_ferrotek_1042.pdf' and d.deleted_flag = 'N')
 order by t.tag_name;

select a.annotation_key
     , a.annotation_value
  from adm_document_annotations a
 where a.document_id = (select d.document_id from adm_documents d where d.document_name = 'inv_ferrotek_1042.pdf' and d.deleted_flag = 'N')
   and a.annotation_key not like 'file.%'
 order by a.annotation_key;

-- ---------------------------------------------------------------------------
-- Read the verdict the classifier stored
-- ---------------------------------------------------------------------------
select r.doc_type
     , r.status
     , r.prompt_tokens
     , r.completion_tokens
     , r.reason
  from hkd_ai_results r
 where r.document_id = (select d.document_id from adm_documents d where d.document_name = 'inv_ferrotek_1042.pdf' and d.deleted_flag = 'N')
 order by r.result_id;
