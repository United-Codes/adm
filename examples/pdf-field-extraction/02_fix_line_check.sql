-- Lesson 2: corrects the line check of the document type invoice for a credit note. A credit note
-- prints a positive quantity and unit price next to a negative amount, so the line check compares
-- the amounts without their signs. Run in SQLcl or SQL*Plus, connected as the ADM schema owner,
-- after 02_add_checks.sql. Calls no model. Running it again sets the same check.

@@settings.sql

set define on
set verify off
set feedback off

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
  l_config.put('line_checks', json_array_t(q'~[
    {"name": "quantity x unit price = amount",
     "expr": "abs(abs(quantity * unit_price) - abs(amount)) <= 0.01"}
  ]~'));

  adm_ai_form_config_api.update_doc_type(
    p_doc_type_id => l_doc_type_id
  , p_config_json => l_config.to_clob
  );
  commit;
end;
/
