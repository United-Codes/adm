-- Lesson 2: adds two field patterns to the form HARBOUR_INVOICE: a discount is a positive number,
-- and every item number looks like a Harbour item number. Run in SQLcl or SQL*Plus, connected as
-- the ADM schema owner. Calls no model. Running it again sets the same patterns.

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_form_id  number;
  l_config   json_object_t;
  l_patterns json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_form_id := adm_ai_form_config_api.get_form_id(
                 p_profile_id => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
               , p_form_code  => 'HARBOUR_INVOICE'
               );
  l_config := json_object_t(adm_ai_form_config_api.get_form_config(l_form_id));

  -- get_object returns a reference: put changes l_config too.
  l_patterns := l_config.get_object('field_patterns'); -- @dblinter ignore(g-2135): a reference into l_config, put below changes l_config
  l_patterns.put('discount_amount', '^[0-9.]+$');
  l_patterns.put('line_items.item_number', '^[A-Z]{3}-[A-Z0-9-]+$');

  adm_ai_form_config_api.update_form(p_form_id => l_form_id, p_config_json => l_config.to_clob);
  commit;
end;
/
