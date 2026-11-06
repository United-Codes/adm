-- Lesson 4: adds a vision model to the profile pfx_supplier_forms, so that it reads images. Run in
-- SQLcl or SQL*Plus, connected as the ADM schema owner. Calls no model. Running it again sets the
-- same model.

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_profile_id number;
  l_config     json_object_t;
  l_vision     json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  -- update_profile replaces the whole configuration: start from the stored one.
  l_config := json_object_t(adm_ai_form_config_api.get_profile_config(l_profile_id));

  -- The same provider, credential and options as the text model, with the vision model of settings.sql.
  l_vision := l_config.get_object('text_model').clone;
  l_vision.put('model', '&pfx_vision_model');
  l_config.put('vision_model', l_vision);

  adm_ai_form_config_api.update_profile(p_profile_id => l_profile_id, p_config_json => l_config.to_clob);
  commit;
end;
/
