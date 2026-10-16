-- Lesson 5: a person reads the scanned delivery note and approves it with the values from the
-- page. The first call has a typing error, so the checks refuse it; the second call is right.
-- Calls no model.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

define pfx_document = 'inbox-harbour-scanned.pdf'

-- ---------------------------------------------------------------------------
-- Approve with a typing error
-- ---------------------------------------------------------------------------
declare
  l_document_id number;
begin
  adm_context_api.system_user_login('&pfx_user');
  select document_id
    into l_document_id
    from adm_my_documents_v
   where folder_path = '&pfx_home/pfx_inbox'
     and document_name = '&pfx_document';

  adm_ai_form_extract_api.approve(
    p_profile_id  => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
  , p_document_id => l_document_id
  , p_form_code   => 'HARBOUR_DELIVERY_NOTE'
  , p_corrections => '{"delivery_note_number": "DN-2026-1190", "delivery_date": "2026-10-01",
                       "customer_number": "C-11502", "customer_name": "Lindqvist Architekten GmbH",
                       "order_reference": "LA-2026-131", "total_quantity": 6}'
  , p_line_items  => '[{"item_number": "WBD-120", "quantity": 2}, {"item_number": "LMP-LED-02", "quantity": 3}]'
  );
  commit;
exception
  when adm_ai_error.e_form_checks_failed then
    rollback;
    sys.dbms_output.put_line(sqlerrm); -- @dblinter ignore(g-5080): the demonstration prints the message of the refused approval
end;
/

-- ---------------------------------------------------------------------------
-- Approve with the right values
-- ---------------------------------------------------------------------------
declare
  l_document_id number;
begin
  adm_context_api.system_user_login('&pfx_user');
  select document_id
    into l_document_id
    from adm_my_documents_v
   where folder_path = '&pfx_home/pfx_inbox'
     and document_name = '&pfx_document';

  adm_ai_form_extract_api.approve(
    p_profile_id  => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
  , p_document_id => l_document_id
  , p_form_code   => 'HARBOUR_DELIVERY_NOTE'
  , p_corrections => '{"delivery_note_number": "DN-2026-1190", "delivery_date": "2026-10-01",
                       "customer_number": "C-11502", "customer_name": "Lindqvist Architekten GmbH",
                       "order_reference": "LA-2026-131", "total_quantity": 5}'
  , p_line_items  => '[{"item_number": "WBD-120", "quantity": 2}, {"item_number": "LMP-LED-02", "quantity": 3}]'
  );
  commit;
  sys.dbms_output.put_line('approved');
end;
/

column document_name format a28
column reviewed_by format a12
select x.document_name
     , x.status
     , x.form_code
     , x.reviewed_by
  from adm_my_form_extractions_v x
 where x.profile_name = 'pfx_supplier_forms'
   and x.document_name = '&pfx_document';

undefine pfx_document
