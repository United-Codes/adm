-- Lesson 7, OPTIONAL, run as a DBA: drop the demo application schema AIC_APP that
-- 22_aic_app_schema.sql created. Run 98_aic_app_teardown.sql as AIC_APP first, so that its APEX
-- application is removed. Re-runnable.
--
--   sql -name <DBA connection> @97_aic_app_schema_drop.sql
--
-- What it does:
--   1. removes AIC_APP from the APEX workspace of the ADM schema
--   2. drops the user AIC_APP with everything in it (UC AI, the agent and its runs)
--
-- Never point the define at a schema that you did not create for this lesson.

set define '&'
set verify off
set serveroutput on
set feedback off

define aic_app_schema = 'AIC_APP'
define adm_schema     = 'ADM'

declare
  l_workspace apex_workspaces.workspace%type;
  l_apps      number;
begin
  select count(*) into l_apps from apex_applications where owner = upper('&aic_app_schema');
  if l_apps > 0 then
    raise_application_error(-20790, upper('&aic_app_schema') || ' still owns ' || l_apps || ' APEX application(s). Run 98_aic_app_teardown.sql as that schema first.');
  end if;

  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = upper('&adm_schema');
  if l_workspace is not null then
    select count(*) into l_apps from apex_workspace_schemas where workspace_name = l_workspace and schema = upper('&aic_app_schema');
    if l_apps > 0 then
      apex_instance_admin.remove_schema(p_workspace => l_workspace, p_schema => upper('&aic_app_schema'));
      commit;
    end if;
  end if;
  sys.dbms_output.put_line('1. ' || upper('&aic_app_schema') || ' removed from the APEX workspace ' || nvl(l_workspace, '(none)')); -- @dblinter ignore(g-5010): script output for the person who runs it
end;
/

declare
  l_exists number;
  l_ddl    varchar2(200 char);
begin
  select case when exists (select 1 from dba_users u where u.username = upper('&aic_app_schema')) then 1 else 0 end
    into l_exists
    from dual;
  if l_exists > 0 then
    l_ddl := 'drop user &aic_app_schema cascade'; -- @dblinter ignore(g-9501): the user name is a define of this script, not user input
    execute immediate l_ddl;
  end if;
  sys.dbms_output.put_line('2. user dropped: ' || upper('&aic_app_schema')); -- @dblinter ignore(g-5010): script output for the person who runs it
end;
/

select count(*) as aic_app_users_left from dba_users where username = upper('&aic_app_schema');
set feedback on
