-- Lesson 3: adds a rule to the form NORDWIND_INVOICE that names the column of the item number.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner. Calls no model. Run it once:
-- running it again adds the rule a second time.

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
               , p_form_code  => 'NORDWIND_INVOICE'
               );
  l_config := json_object_t(adm_ai_form_config_api.get_form_config(l_form_id));

  l_rules := l_config.get_array('rules'); -- @dblinter ignore(g-2135): a reference into l_config, append below changes l_config
  l_rules.append('The item number of a line is the value in the "Code" column.');

  adm_ai_form_config_api.update_form(p_form_id => l_form_id, p_config_json => l_config.to_clob);
  commit;
end;
/
