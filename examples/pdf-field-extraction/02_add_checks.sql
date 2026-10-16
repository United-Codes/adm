-- Lesson 2: adds the arithmetic checks of an invoice to the document type invoice. They apply to
-- every invoice form of the profile. Run in SQLcl or SQL*Plus, connected as the ADM schema owner.
-- Calls no model. Running it again sets the same checks.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

declare
  l_doc_type_id number;
  l_config      json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_doc_type_id := adm_ai_form_config_api.get_doc_type_id(
                     p_profile_id => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
                   , p_doc_type   => 'invoice'
                   );

  -- Start from the stored configuration: update_doc_type replaces all of it.
  l_config := json_object_t(adm_ai_form_config_api.get_doc_type_config(l_doc_type_id));

  -- ---------------------------------------------------------------------------
  -- Add the checks of an invoice
  -- ---------------------------------------------------------------------------
  -- A credit note prints a positive quantity and unit price next to a negative amount.
  l_config.put('line_checks', json_array_t(q'~[
    {"name": "quantity x unit price = amount",
     "expr": "abs(abs(quantity * unit_price) - abs(amount)) <= 0.01"}
  ]~'));
  -- EN 16931 BR-CO-13 and BR-CO-15. The discount takes the sign of the invoice.
  l_config.put('checks', json_array_t(q'~[
    {"name": "sum of lines - discount = net amount",
     "expr": "abs(sum_amount - sign(sum_amount) * abs(nvl(discount_amount, 0)) - net_amount) <= 0.01"},
    {"name": "net amount + VAT = total",
     "expr": "abs(net_amount + vat_amount - total_amount) <= 0.01"},
    {"name": "net amount x VAT rate = VAT",
     "expr": "abs(round(net_amount * vat_rate / 100, 2) - vat_amount) <= 0.01"}
  ]~'));

  adm_ai_form_config_api.update_doc_type(
    p_doc_type_id => l_doc_type_id
  , p_config_json => l_config.to_clob
  );
  commit;
  sys.dbms_output.put_line('document type invoice: 1 line check, 3 checks');
end;
/

-- ---------------------------------------------------------------------------
-- Show the SQL of a check
-- ---------------------------------------------------------------------------
declare
  l_profile_id number;
  l_schema     clob;
begin
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  l_schema := json_object_t(
                adm_ai_form_config_api.get_doc_type_config(adm_ai_form_config_api.get_doc_type_id(l_profile_id, 'invoice'))
              ).get_object('json_schema').to_clob;

  sys.dbms_output.put_line(adm_ai_form_config_api.validate_expression(
    p_json_schema => l_schema
  , p_expression  => 'abs(net_amount + vat_amount - total_amount) <= 0.01'
  ));
  -- A token that is not allowed is refused, before anything runs.
  sys.dbms_output.put_line(adm_ai_form_config_api.validate_expression(
    p_json_schema => l_schema
  , p_expression  => 'total_amount > (select max(total_amount) from invoices)'
  ));
exception
  when adm_ai_error.e_form_expression then
    sys.dbms_output.put_line(sqlerrm); -- @dblinter ignore(g-5080): the demonstration prints the message of the refused expression
end;
/
