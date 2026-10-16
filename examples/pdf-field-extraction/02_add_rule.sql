-- Lesson 2: adds a rule about the discount to the form HARBOUR_INVOICE. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner. Calls no model. Run it once: running it again adds the rule
-- a second time.

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_form_id number;
  l_config  json_object_t;
  l_rules   json_array_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_form_id := adm_ai_form_config_api.get_form_id(
                 p_profile_id => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
               , p_form_code  => 'HARBOUR_INVOICE'
               );
  l_config := json_object_t(adm_ai_form_config_api.get_form_config(l_form_id));

  -- get_array returns a reference: append changes l_config too.
  l_rules := l_config.get_array('rules'); -- @dblinter ignore(g-2135): a reference into l_config, append below changes l_config
  l_rules.append(
    'The discount is the "Discount" row of the totals block, as a positive number. Without that row it is 0.'
  );

  adm_ai_form_config_api.update_form(p_form_id => l_form_id, p_config_json => l_config.to_clob);
  commit;
end;
/
