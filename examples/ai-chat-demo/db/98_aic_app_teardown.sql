-- Lesson 7: removes what the lesson created in the APPLICATION schema. Run as that schema (AIC_APP).
-- Re-runnable: what is already gone is skipped.
--
--   sql aic_app@<host>:<port>/<service> @98_aic_app_teardown.sql
--
-- What goes:
--   1. the runs of aic_app_assistant, the agent, the prompt profile AIC_APP_ASSISTANT and the two tools
--   2. the package aic_app_tools_api and the synonym aic_rag_bridge_api
--   3. the application "AIC App" of 22b_aic_app_application.sql, if it exists
--
-- UC AI itself stays. If you use the demo schema AIC_APP, a DBA can drop the whole schema afterwards
-- with 97_aic_app_schema_drop.sql. The ADM side (the bridge, its grant and the ADM user AIC_SERVICE)
-- goes with 99_aic_teardown.sql in the ADM schema.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

declare
  l_n number;
begin
  select case when exists (select 1 from uc_ai_agents a where a.code = 'aic_app_assistant') then 1 else 0 end
    into l_n
    from dual;
  if l_n > 0 then
    uc_ai_agents_api.purge_agent('aic_app_assistant');   -- every version, all runs and sessions
  end if;
  delete from uc_ai_prompt_profiles where code = 'AIC_APP_ASSISTANT';
  delete from uc_ai_tools where code in ('AIC_APP_SEARCH_CONTRACTS', 'AIC_APP_SEARCH_POLICIES');   -- parameters and tags cascade
  commit;
  sys.dbms_output.put_line('1. agent, runs, prompt profile and tools removed');
end;
/

declare
  procedure drop_if_exists (p_type in varchar2, p_name in varchar2) as
    l_exists number;
    l_ddl    varchar2(200 char);
  begin
    select case when exists (select 1 from user_objects o where o.object_type = p_type and o.object_name = upper(p_name)) then 1 else 0 end
      into l_exists
      from dual;
    if l_exists > 0 then
      l_ddl := 'drop ' || p_type || ' ' || p_name; -- @dblinter ignore(g-9501): p_type and p_name are literals of this script, never user input
      execute immediate l_ddl;
    end if;
  end drop_if_exists;
begin
  drop_if_exists('PACKAGE', 'aic_app_tools_api');
  drop_if_exists('SYNONYM', 'aic_rag_bridge_api');
  sys.dbms_output.put_line('2. package and synonym removed');
end;
/

declare
  l_workspace apex_workspaces.workspace%type;
begin
  <<app_loop>>
  for a in (select application_id, workspace from apex_applications where owner = user and alias = 'AIC-APP') loop
    l_workspace := a.workspace;
    apex_application_install.set_workspace(l_workspace);
    apex_application_install.remove_application(p_application_id => a.application_id);
    sys.dbms_output.put_line('3. application removed: ' || a.application_id);
  end loop app_loop;
  commit;
end;
/

prompt
prompt What is left of lesson 7 in this schema (every count must be 0):
select 'uc_ai agents' as what, count(*) as n from uc_ai_agents where code = 'aic_app_assistant'
union all select 'uc_ai profiles', count(*) from uc_ai_prompt_profiles where code = 'AIC_APP_ASSISTANT'
union all select 'uc_ai tools',    count(*) from uc_ai_tools where code like 'AIC\_APP\_%' escape '\'
union all select 'aic objects',    count(*) from user_objects where object_name like 'AIC\_%' escape '\'
union all select 'applications',   count(*) from apex_applications where owner = user and alias = 'AIC-APP';
set feedback on
