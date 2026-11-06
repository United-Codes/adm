-- Lesson 7, OPTIONAL: an empty APEX application for the demo schema AIC_APP. Run as AIC_APP, after
-- 22_aic_app_schema.sql and the UC AI install. Re-runnable: if this schema owns an application
-- already, the script does nothing.
--
--   sql aic_app@<host>:<port>/<service> @22b_aic_app_application.sql
--
-- Why. UC AI runs the code of a tool in the parsing schema of the APEX application of the session.
-- An agent of this schema therefore needs an APEX session in an application of this schema. Your own
-- application schema has an application already; the demo schema has none. This script creates
-- "AIC App" with no pages, in the workspace of the schema, with a new application ID.
-- It uses the same calls as an APEX export file. 98_aic_app_teardown.sql removes it.

set define off
set serveroutput on
set feedback off

declare
  l_workspace apex_workspaces.workspace%type;
  l_app_id    apex_applications.application_id%type;
begin
  select min(application_id) into l_app_id from apex_applications where owner = user;
  if l_app_id is not null then
    sys.dbms_output.put_line('This schema owns application ' || l_app_id || ' already. Nothing to do.'); -- @dblinter ignore(g-5010): script output for the person who runs it
    return;
  end if;

  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
  if l_workspace is null then
    raise_application_error(-20790, 'This schema is in no APEX workspace. Run 22_aic_app_schema.sql as a DBA first.');
  end if;

  apex_application_install.set_workspace(l_workspace);
  apex_application_install.generate_application_id;
  apex_application_install.generate_offset;
  apex_application_install.set_schema(user);
  apex_application_install.set_application_alias('AIC-APP');

  wwv_flow_imp.import_begin(
    p_version_yyyy_mm_dd     => '2024.11.30'
  , p_release                => '24.2.0'
  , p_default_workspace_id   => apex_util.find_security_group_id(p_workspace => l_workspace)
  , p_default_application_id => 1
  , p_default_id_offset      => 0
  , p_default_owner          => user
  );

  wwv_imp_workspace.create_flow(
    p_id                         => wwv_flow.g_flow_id
  , p_owner                      => user
  , p_name                       => 'AIC App'
  , p_alias                      => 'AIC-APP'
  , p_page_view_logging          => 'NO'
  , p_flow_language              => 'en'
  , p_flow_language_derived_from => 'FLOW_PRIMARY_LANGUAGE'
  , p_flow_status                => 'AVAILABLE_W_EDIT_LINK'
  , p_flow_version               => '1'
  , p_compatibility_mode         => '24.2'
  );

  wwv_flow_imp.import_end(p_auto_install_sup_obj => false);
  commit;

  select min(application_id) into l_app_id from apex_applications where owner = user;
  sys.dbms_output.put_line('Application ' || l_app_id || ' "AIC App" created in the workspace ' || l_workspace); -- @dblinter ignore(g-5010): script output for the person who runs it
end;
/
set feedback on
