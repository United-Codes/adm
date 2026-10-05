-- Lesson 3: classify a document again, and see what a re-run leaves alone. Run in SQLcl or
-- SQL*Plus, connected as the ADM schema owner, after lesson 2:
--
--   @03_rerun.sql
--
-- It waits for the worker once and makes one model call, so it takes about 15 seconds.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column workflow_code format a16
column status format a8
column summary format a110
column document_name format a30
column tag_name format a10
column tag_value format a12
column updated_by format a12

-- ---------------------------------------------------------------------------
-- Keep a category tag that a person set
-- ---------------------------------------------------------------------------
-- A person changes the category of the datasheet to "other". The classifier runs as the system
-- user, so a tag written by anybody else is a tag a person set.
declare
  l_doc_id adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  select document_id into l_doc_id from adm_documents where document_name = 'datasheet_pump_x200.pdf' and deleted_flag = 'N';
  adm_tag_api.add_tag_to_document(l_doc_id, 'category', 'other');
end;
/

-- Queue the document for classification again.
declare
  l_doc_id adm_documents.document_id%type;
begin
  adm_context_api.system_login;
  select document_id into l_doc_id from adm_documents where document_name = 'datasheet_pump_x200.pdf' and deleted_flag = 'N';
  hkd_ai_api.reclassify(l_doc_id);
  commit;
end;
/
@wait.sql

select w.workflow_code
     , w.status
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'datasheet_pump_x200.pdf' and d.deleted_flag = 'N')
 order by w.run_id desc
 fetch first 1 row only;

select t.tag_name
     , dt.tag_value
     , dt.updated_by
  from adm_document_tags dt
  join adm_tags t
    on t.tag_id = dt.tag_id
 where dt.document_id = (select d.document_id from adm_documents d where d.document_name = 'datasheet_pump_x200.pdf' and d.deleted_flag = 'N')
   and t.tag_name     = 'category';
