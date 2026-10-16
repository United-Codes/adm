-- Lesson 5: extracts the new documents of the profile pfx_supplier_forms now, in this session,
-- instead of waiting for the AI queue job. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner. Calls the model for each new document.

@@settings.sql

set define on
set verify off
set feedback off

begin
  adm_context_api.system_user_login('&pfx_user');
  adm_ai_form_extract_api.process_new_documents(
    p_profile_id => adm_ai_form_config_api.get_profile_id('pfx_supplier_forms')
  );
  commit;
end;
/
