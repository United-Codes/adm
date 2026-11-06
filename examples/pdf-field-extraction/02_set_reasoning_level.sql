-- Lesson 2: sets the reasoning level of the text model of the profile, or removes it. The level
-- applies to a run that turns reasoning on. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner. Calls no model. Arguments:
--
--   @02_set_reasoning_level.sql high   -- low, medium or high
--   @02_set_reasoning_level.sql none   -- removes the level: the provider decides

@@settings.sql

set define on
set verify off
set feedback off

declare
  l_profile_id number;
  l_config     json_object_t;
  l_model      json_object_t;
  l_model_cfg  json_object_t;
begin
  adm_context_api.system_user_login('&pfx_user');
  l_profile_id := adm_ai_form_config_api.get_profile_id('pfx_supplier_forms');

  -- Start from the stored configuration: update_profile replaces all of it.
  l_config    := json_object_t(adm_ai_form_config_api.get_profile_config(l_profile_id));
  l_model     := l_config.get_object('text_model'); -- @dblinter ignore(g-2135): a reference into l_config, the changes below change l_config
  l_model_cfg := l_model.get_object('config'); -- @dblinter ignore(g-2135): a reference into l_config, the changes below change l_config
  if lower('&1') = 'none' then
    l_model_cfg.remove('g_reasoning_level');
  else
    l_model_cfg.put('g_reasoning_level', lower('&1'));
  end if;

  adm_ai_form_config_api.update_profile(
    p_profile_id  => l_profile_id
  , p_config_json => l_config.to_clob
  );
  commit;
end;
/

undefine 1
