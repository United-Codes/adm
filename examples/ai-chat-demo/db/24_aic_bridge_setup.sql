-- Lesson 7: the ADM side of a search from another schema. Run as the ADM schema owner, after lesson 7
-- (or at least after install.sql and aic_policies). Re-runnable. Calls no model.
--
--   sql -name <connection> @24_aic_bridge_setup.sql
--
-- It creates:
--   1. the ADM user AIC_SERVICE, role VIEWER, member of the group AIC_LEGAL only. Every search through
--      the bridge runs as this user, so it decides what the other application sees.
--   2. the package aic_rag_bridge_api (23_aic_rag_bridge_api.pks/.pkb)
--   3. one grant: EXECUTE on aic_rag_bridge_api to the application schema. Nothing else: not
--      adm_ai_rag_api, not adm_context_api, not a table.
--
-- The application schema must exist (22_aic_app_schema.sql creates the demo schema AIC_APP). If you use
-- a schema of your own, change the define below. 99_aic_teardown.sql removes all three again.

set define '&'
set verify off
set serveroutput on
set feedback off

define aic_app_schema = 'AIC_APP'

whenever sqlerror exit failure

prompt === 1. the service user AIC_SERVICE ===
declare
  l_role_id  adm_roles.role_id%type;
  l_group_id adm_groups.group_id%type;
  l_user_id  adm_users.user_id%type;
  l_exists   number;
begin
  adm_context_api.system_login;

  select count(*) into l_exists from all_users where username = upper('&aic_app_schema');
  if l_exists = 0 then
    raise_application_error(-20790, 'The schema &aic_app_schema does not exist. Run 22_aic_app_schema.sql as a DBA, or set the define aic_app_schema.');
  end if;

  select count(*) into l_exists from adm_users where username = 'AIC_SERVICE';
  if l_exists = 0 then
    select role_id into l_role_id from adm_roles where role_name = 'VIEWER';
    adm_user_api.add_user(p_username => 'AIC_SERVICE', p_role_id => l_role_id);
  end if;

  select user_id  into l_user_id  from adm_users  where username   = 'AIC_SERVICE';
  select group_id into l_group_id from adm_groups where group_name = 'AIC_LEGAL';

  select count(*)
    into l_exists
    from adm_group_members m
   where m.group_id = l_group_id
     and m.user_id  = l_user_id;
  if l_exists = 0 then
    adm_group_api.add_user_to_group(p_group_id => l_group_id, p_user_id => l_user_id);
  end if;
  commit;
  -- the system user only for this block: a later statement in this session runs as nobody
  adm_context_api.clear_context;
exception
  when others then
    adm_context_api.clear_context;
    raise;
end;
/

prompt === 2. the package aic_rag_bridge_api ===
set define off
@@23_aic_rag_bridge_api.pks
@@23_aic_rag_bridge_api.pkb
set define '&'

prompt === 3. the grant ===
grant execute on aic_rag_bridge_api to &aic_app_schema;

whenever sqlerror continue

prompt
col what   format a32
col detail format a80
select 'service user' as what, u.username || ' (' || r.role_name || '), groups: '
       || (select listagg(g.group_name, ', ') within group (order by g.group_name)
             from adm_group_members m join adm_groups g on g.group_id = m.group_id
            where m.user_id = u.user_id) as detail
  from adm_users u join adm_roles r on r.role_id = u.role_id
 where u.username = 'AIC_SERVICE'
union all
select 'package', object_type || ' ' || status from user_objects where object_name = 'AIC_RAG_BRIDGE_API'
union all
select 'grants on ADM objects to ' || upper('&aic_app_schema'), listagg(table_name || ' (' || privilege || ')', ', ') within group (order by table_name)
  from user_tab_privs_made where grantee = upper('&aic_app_schema');
set feedback on
