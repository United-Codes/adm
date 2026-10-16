-- Lesson 5: points the profile pfx_supplier_forms at the inbox folder pfx_inbox and lets the AI
-- queue job extract its new documents. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner. Calls no model. Running it again sets the same values.

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_profile_id number;
  l_config     json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');
  -- update_profile replaces the whole configuration: start from the stored one.
  l_config := json_object_t(adm_ai_form_config_api.get_profile_config(l_profile_id));

  l_config.put('source_folder_path', '&pfx_home/pfx_inbox');
  l_config.put('process_new_documents', true);
  l_config.put('max_documents_per_run', 20);

  adm_ai_form_config_api.update_profile(p_profile_id => l_profile_id, p_config_json => l_config.to_clob);
  commit;
end;
/
