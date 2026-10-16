-- Lesson 5: prints the results of the inbox, the documents that wait for a person, the
-- annotations, and the invoices that the hook copied into pfx_invoices. Calls no model.

@@settings.sql

set define on
set verify off
set feedback off
set linesize 220
set pagesize 100

begin
  adm_context_api.system_user_login('&pfx_user');
end;
/

column document_name format a28
column form_code format a22
column issues format a80 word_wrapped
select x.document_name
     , x.status
     , x.method
     , x.form_code
     , replace(x.issues, chr(10), '; ') as issues
  from adm_my_form_extractions_v x
  join adm_my_documents_v d
    on d.document_id = x.document_id
 where x.profile_name = 'pfx_supplier_forms'
   and d.folder_path = '&pfx_home/pfx_inbox'
 order by x.document_name;

column tag_name format a20
select d.document_name
     , t.tag_name
  from adm_my_document_tags_v t
  join adm_my_documents_v d
    on d.document_id = t.document_id
 where d.folder_path = '&pfx_home/pfx_inbox'
 order by d.document_name;

column annotation_key format a36
column annotation_value format a20
select d.document_name
     , a.annotation_key
     , a.annotation_value
  from adm_my_document_annotations_v a
  join adm_my_documents_v d
    on d.document_id = a.document_id
 where d.folder_path = '&pfx_home/pfx_inbox'
   and a.annotation_key not like 'file.%'
 order by d.document_name, a.annotation_key;

column invoice_number format a16
column customer_name format a30
column total_amount format a12
select i.invoice_number
     , to_char(i.invoice_date, 'YYYY-MM-DD') as invoice_date
     , substr(i.customer_name, 1, 30) as customer_name
     , to_char(i.total_amount, 'fm999999990.00') as total_amount
     , i.line_count
     , i.source_status
  from pfx_invoices i
 order by i.invoice_number;
