-- Lesson 3: replaces the markers of one form. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner. Calls no model. The other keys of the form stay as they are. Arguments:
--
--   @03_set_markers.sql <form code> <JSON array of regular expressions>
--   @03_set_markers.sql HARBOUR_DELIVERY_NOTE '["VAT ID DE 812 334 905"]'

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_profile_id number;
  l_form_id    number;
  l_config     json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  l_form_id := adm_ai_form_config_api.get_form_id(
                 p_profile_id => l_profile_id
               , p_form_code  => '&1'
               );
  l_config := json_object_t(adm_ai_form_config_api.get_form_config(l_form_id));
  l_config.put('markers', json_array_t(q'~&2~'));

  adm_ai_form_config_api.update_form(p_form_id => l_form_id, p_config_json => l_config.to_clob);
  commit;
end;
/

undefine 1 2
