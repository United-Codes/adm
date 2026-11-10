-- Lesson 7, OPTIONAL, run as a DBA: create the demo application schema AIC_APP.
--
--   sql -name <DBA connection> @22_aic_app_schema.sql
--
-- Skip this script if you already have an application schema with UC AI in the APEX workspace of
-- the ADM schema. Then put its name into the define aic_app_schema of 24_aic_bridge_setup.sql and
-- 27_aic_app_register.sql, and run neither this script nor 97_aic_app_schema_drop.sql.
--
-- What it does, and nothing else:
--   1. creates the database user AIC_APP with a DEMO PASSWORD (below), and the role DB_DEVELOPER_ROLE
--      (Oracle 23ai; it holds create session, table, view, sequence, procedure, type, trigger,
--      synonym and job, which the UC AI install needs)
--   2. adds AIC_APP to the APEX workspace of the ADM schema. UC AI calls the model through the APEX
--      web credential OPENAI, which belongs to that workspace, so the application schema must be in
--      the same workspace.
--
-- The DEMO PASSWORD is written in this file, so everybody who has the file knows it. Use it on a
-- local database only. 97_aic_app_schema_drop.sql removes the user and the workspace assignment.
-- No network ACL is needed: APEX makes the HTTP calls of UC AI.

set define '&'
set verify off
set serveroutput on
set feedback off

define aic_app_schema   = 'AIC_APP'
define adm_schema       = 'ADM'
define aic_app_password = 'Aic-App-Demo-2026'

whenever sqlerror exit failure

declare
  l_exists number;
  l_ddl    varchar2(200 char);
begin
  select case when exists (select 1 from dba_users u where u.username = upper('&aic_app_schema')) then 1 else 0 end
    into l_exists
    from dual;
  if l_exists = 0 then
    l_ddl := 'create user &aic_app_schema identified by "&aic_app_password" quota unlimited on users'; -- @dblinter ignore(g-9501): the user name and the password are defines of this script, not user input
    execute immediate l_ddl;
    sys.dbms_output.put_line('1. user created: ' || upper('&aic_app_schema')); -- @dblinter ignore(g-5010): script output for the person who runs it
  else
    sys.dbms_output.put_line('1. user exists:  ' || upper('&aic_app_schema')); -- @dblinter ignore(g-5010): script output for the person who runs it
  end if;
end;
/

grant db_developer_role to &aic_app_schema;

declare
  l_workspace apex_workspaces.workspace%type;
  l_assigned  number;
begin
  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = upper('&adm_schema');
  if l_workspace is null then
    raise_application_error(-20790, 'The schema &adm_schema is in no APEX workspace. Set the define adm_schema to the ADM schema.');
  end if;

  select case
           when exists (select 1
                          from apex_workspace_schemas s
                         where s.workspace_name = l_workspace
                           and s.schema = upper('&aic_app_schema')) then 1
           else 0
         end
    into l_assigned
    from dual;

  if l_assigned = 0 then
    apex_instance_admin.add_schema(p_workspace => l_workspace, p_schema => upper('&aic_app_schema'));
    commit;
  end if;
  sys.dbms_output.put_line('2. ' || upper('&aic_app_schema') || ' is in the APEX workspace ' || l_workspace); -- @dblinter ignore(g-5010): script output for the person who runs it
end;
/

whenever sqlerror continue
set feedback on
