-- Lesson 2: shows what the checks of the form and the document type report for a wrong value.
-- It takes the stored result of harbour-invoice-01-standard.pdf (lesson 1) and calls approve with
-- one wrong corrected value at a time. approve runs the checks on the corrected values and
-- refuses the approval when one fails, so the calls change nothing. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after 02_add_patterns.sql. Calls no model.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on
set linesize 220

declare
  l_profile_id  number;
  l_document_id number;

  procedure try_value (
    p_corrections in varchar2
  )
  as
  begin
    sys.dbms_output.put_line('Corrected value: ' || p_corrections);
    adm_ai_form_extract_api.approve(
      p_profile_id      => l_profile_id -- @dblinter ignore(g-7130): try_value is a helper of this one block, and the profile is the state of the block
    , p_document_id     => l_document_id -- @dblinter ignore(g-7130): try_value is a helper of this one block, and the document is the state of the block
    , p_corrections     => p_corrections
    , p_add_to_test_set => false
    );
    sys.dbms_output.put_line('  approved');
  exception
    when adm_ai_error.e_form_checks_failed then
      sys.dbms_output.put_line('  ' || replace(sqlerrm, chr(10), chr(10) || '  ')); -- @dblinter ignore(g-5080): the demonstration prints the refusal
  end try_value;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  select document_id
    into l_document_id
    from adm_my_documents_v
   where folder_path = '&pfx_home/pfx_samples'
     and document_name = 'harbour-invoice-01-standard.pdf';

  try_value('{"total_amount": 575.63}');
  try_value('{"invoice_date": "14.03.2026"}');
  try_value('{"discount_amount": -39.37}');
end;
/
