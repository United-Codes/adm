-- Lesson 3: a file the model cannot read. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after lesson 2:
--
--   @03_failures.sql
--
-- The file has the name and type of a PDF but no PDF inside. The provider refuses it, and the
-- refusal is the same on every try, so the classifier records it and does not raise.
-- Uses one model call that fails.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column workflow_code format a20
column status format a8
column attempt format 999
column summary format a110
column doc_type format a10
column reason format a100

-- ---------------------------------------------------------------------------
-- Upload a file that is not a PDF
-- ---------------------------------------------------------------------------
declare
  l_folder_id adm_folders.folder_id%type;
  l_doc_id    adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  l_folder_id := adm_folder_api.get_folder_id('/users/' || lower('&hkd_user') || '/hkd_inbox');

  l_doc_id := adm_document_api.create_document( -- @dblinter ignore(g-2135): create_document is a function, and this script does not need the id
    p_folder_id      => l_folder_id
  , p_document_name  => 'broken_scan.pdf'
  , p_file_content   => sys.utl_raw.cast_to_raw('This is not a PDF file.')
  , p_file_mime_type => 'application/pdf'
  );

  -- The upload hook queued its event in this transaction. The worker sees it at the commit.
  commit;
end;
/
@wait.sql

-- ---------------------------------------------------------------------------
-- Read the outcome
-- ---------------------------------------------------------------------------
-- One run, attempt 1: the classifier did not raise, so the queue did not deliver the message again.
select w.workflow_code
     , w.status
     , w.attempt
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'broken_scan.pdf' and d.deleted_flag = 'N')
 order by w.run_id;

select r.status
     , r.reason
  from hkd_ai_results r
 where r.document_id = (select d.document_id from adm_documents d where d.document_name = 'broken_scan.pdf' and d.deleted_flag = 'N')
 order by r.result_id;
