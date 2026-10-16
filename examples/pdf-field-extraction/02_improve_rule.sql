-- Lesson 2: replaces the discount rule of 02_add_rule.sql with a rule that quotes the printed
-- value. Run in SQLcl or SQL*Plus, connected as the ADM schema owner, after 02_add_rule.sql.
-- Calls no model.

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

  -- The discount rule is the last rule of the form: replace it.
  l_rules := l_config.get_array('rules');
  l_rules.remove(l_rules.get_size - 1);
  l_rules.append(
    'The "Discount" row of the totals block prints the discount with a minus sign, for example "-39,37". '
    || 'Return it as a positive number: 39.37. Without that row the discount is 0.'
  );

  adm_ai_form_config_api.update_form(p_form_id => l_form_id, p_config_json => l_config.to_clob);
  commit;
end;
/
