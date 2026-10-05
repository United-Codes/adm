-- Lesson 4: review the held verdicts, and take a release back. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after lesson 3:
--
--   @04_review.sql
--
-- It acts as the ADM user named below, the way a reviewer would. It queues two documents for
-- classification again to show that the classifier keeps the decision of a person, so it waits
-- for the worker twice. It makes no model call: both runs end before the model.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column result_id format 9999 heading ID
column document_name format a34
column doc_type format a10
column status format a13
column reason format a80
column annotation_key format a14
column annotation_value format a12
column tag_name format a13
column tag_value format a10
column workflow_code format a16
column summary format a95

-- ---------------------------------------------------------------------------
-- List the verdicts that wait for a person
-- ---------------------------------------------------------------------------
select v.result_id
     , v.document_name
     , v.doc_type
     , v.reason
  from hkd_ai_latest_v v
 where v.status = 'NEEDS_REVIEW'
 order by v.created_at;

-- ---------------------------------------------------------------------------
-- Accept a verdict
-- ---------------------------------------------------------------------------
-- The reviewer confirms that the employment letter is an HR letter. Accepting applies the
-- verdict the way a release does: the category tag stays, the needs-review tag goes, and the
-- kb.hr annotation appears.
declare
  l_result_id hkd_ai_results.result_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  select v.result_id into l_result_id from hkd_ai_latest_v v where v.document_name = 'letter_employment_change.pdf';
  hkd_ai_api.accept(l_result_id);
  commit;
end;
/

select a.annotation_key
     , a.annotation_value
  from adm_document_annotations a
 where a.document_id = (select d.document_id from adm_documents d where d.document_name = 'letter_employment_change.pdf' and d.deleted_flag = 'N')
   and a.annotation_key not like 'file.%'
 order by a.annotation_key;

-- ---------------------------------------------------------------------------
-- Keep an accepted verdict when the document is classified again
-- ---------------------------------------------------------------------------
-- The classifier does not replace a verdict that a person accepted, so this run ends before it
-- calls the model.
declare
  l_document_id adm_documents.document_id%type;
begin
  adm_context_api.system_login;
  select d.document_id into l_document_id from adm_documents d where d.document_name = 'letter_employment_change.pdf' and d.deleted_flag = 'N';
  hkd_ai_api.reclassify(l_document_id);
  commit;
end;
/
@wait.sql

select w.workflow_code
     , w.status
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'letter_employment_change.pdf' and d.deleted_flag = 'N')
   and w.workflow_code = 'AI_RECLASSIFY'
 order by w.run_id desc
 fetch first 1 row only;

-- ---------------------------------------------------------------------------
-- Accept a verdict with another type
-- ---------------------------------------------------------------------------
-- To show the mechanism, the reviewer files the scanned fax as "other", although the model said
-- "contract". p_doc_type replaces the model's type, and the kb annotation follows.
declare
  l_result_id hkd_ai_results.result_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  select v.result_id into l_result_id from hkd_ai_latest_v v where v.document_name = 'scan_fax_amendment.pdf';
  hkd_ai_api.accept(l_result_id, p_doc_type => 'other');
  commit;
end;
/

select v.document_name
     , v.doc_type
     , v.status
     , v.reviewed_by
  from hkd_ai_latest_v v
 where v.document_name = 'scan_fax_amendment.pdf';

-- ---------------------------------------------------------------------------
-- Check a sample of the released verdicts
-- ---------------------------------------------------------------------------
-- Released verdicts nobody looks at can be wrong. Read a few at random every week, and read
-- all of one type after you changed its description.
select v.result_id
     , v.document_name
     , v.doc_type
     , v.reason
  from hkd_ai_latest_v v
 where v.status = 'RELEASED'
 order by sys.dbms_random.value
 fetch first 3 rows only;

-- ---------------------------------------------------------------------------
-- Take a release back
-- ---------------------------------------------------------------------------
-- The reviewer finds that the quote should not be released after all.
declare
  l_document_id adm_documents.document_id%type;
begin
  adm_context_api.system_user_login('&hkd_user');
  select document_id into l_document_id from adm_documents where document_name = 'quote_alpenwerk_q5531.pdf' and deleted_flag = 'N';
  hkd_ai_api.revoke_release(l_document_id);
  commit;
end;
/

select a.annotation_key
     , a.annotation_value
  from adm_document_annotations a
 where a.document_id = (select d.document_id from adm_documents d where d.document_name = 'quote_alpenwerk_q5531.pdf' and d.deleted_flag = 'N')
   and a.annotation_key not like 'file.%'
 order by a.annotation_key;

select t.tag_name
     , dt.tag_value
  from adm_document_tags dt
  join adm_tags t
    on t.tag_id = dt.tag_id
 where dt.document_id = (select d.document_id from adm_documents d where d.document_name = 'quote_alpenwerk_q5531.pdf' and d.deleted_flag = 'N')
 order by t.tag_name;

-- ---------------------------------------------------------------------------
-- Keep a revoked release when the document is classified again
-- ---------------------------------------------------------------------------
-- A release that a person took back stays back. Without this, the next run could release the quote
-- again.
declare
  l_document_id adm_documents.document_id%type;
begin
  adm_context_api.system_login;
  select d.document_id into l_document_id from adm_documents d where d.document_name = 'quote_alpenwerk_q5531.pdf' and d.deleted_flag = 'N';
  hkd_ai_api.reclassify(l_document_id);
  commit;
end;
/
@wait.sql

select w.workflow_code
     , w.status
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'quote_alpenwerk_q5531.pdf' and d.deleted_flag = 'N')
   and w.workflow_code = 'AI_RECLASSIFY'
 order by w.run_id desc
 fetch first 1 row only;
