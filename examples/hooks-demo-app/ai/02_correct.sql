-- Lesson 2: correct the answer for the pro forma invoice by changing two type descriptions.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner, after 02_measure.sql:
--
--   @02_correct.sql
--
-- It queues one document for classification again and waits for the worker, so it uses one
-- model call.

set serveroutput on
set feedback off
set linesize 200
column document_name format a32
column doc_type format a10
column status format a9
column annotation_key format a14
column annotation_value format a12
column description format a100

-- ---------------------------------------------------------------------------
-- Reword the descriptions of two types
-- ---------------------------------------------------------------------------
-- The model reads these descriptions as the definition of each type. The text changes the
-- question, so no code changes.
update hkd_ai_doc_types
   set description = 'A tax invoice from a supplier that is booked and paid: invoice number, items, amount due. Not a pro forma invoice, not a reminder about an earlier invoice'
 where doc_type = 'invoice';

update hkd_ai_doc_types
   set description = 'An offer with prices that is not booked yet. A pro forma invoice for prepayment belongs here'
 where doc_type = 'quote';

commit;

-- ---------------------------------------------------------------------------
-- Classify the pro forma invoice again
-- ---------------------------------------------------------------------------
declare
  l_document_id adm_documents.document_id%type;
begin
  adm_context_api.system_login;
  select document_id
    into l_document_id
    from adm_documents
   where document_name = 'proforma_alpenwerk_pf5531.pdf'
     and deleted_flag  = 'N';
  hkd_ai_api.reclassify(l_document_id);
  commit;
end;
/
@wait.sql

-- Both verdicts are in the history. The kb annotation follows the newest one.
select r.result_id
     , r.doc_type
     , r.status
  from hkd_ai_results r
 where r.document_id = (select d.document_id from adm_documents d where d.document_name = 'proforma_alpenwerk_pf5531.pdf' and d.deleted_flag = 'N')
 order by r.result_id;

select a.annotation_key
     , a.annotation_value
  from adm_document_annotations a
 where a.document_id = (select d.document_id from adm_documents d where d.document_name = 'proforma_alpenwerk_pf5531.pdf' and d.deleted_flag = 'N')
   and a.annotation_key not like 'file.%'
 order by a.annotation_key;
