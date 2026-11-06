-- Lesson 6: let an ADM administrator see the policies, so that the test console of the RAG
-- collection manager finds them. Run as the ADM schema owner, with the ADM username of the
-- administrator who uses the console:
--
--   sql -name <connection> @14b_aic_admin_sees_policies.sql MY_ADMIN
--
-- The test console searches as the administrator who is logged in, with the access of that person:
-- the documents the person owns, and the documents of their groups and shares. The ADMIN role does
-- not open the other documents in a search. The policies are in the group folder /groups/aic_hr, so
-- this script adds the administrator to the group AIC_HR. Re-runnable. 99_aic_teardown.sql removes
-- the membership with the group.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

define aic_admin = '&1'
set define on
set verify off
set serveroutput on
set feedback off

declare
  l_group_id adm_groups.group_id%type;
  l_user_id  adm_users.user_id%type;
  l_exists   number;
begin
  adm_context_api.system_login;

  select group_id into l_group_id from adm_groups where group_name = 'AIC_HR';
  select user_id  into l_user_id  from adm_users  where username   = upper('&aic_admin');

  select case when exists (select 1 from adm_group_members m where m.group_id = l_group_id and m.user_id = l_user_id) then 1 else 0 end
    into l_exists
    from dual;

  if l_exists = 0 then
    adm_group_api.add_user_to_group(p_group_id => l_group_id, p_user_id => l_user_id);
    sys.dbms_output.put_line(upper('&aic_admin') || ' is now a member of the group AIC_HR');
  else
    sys.dbms_output.put_line(upper('&aic_admin') || ' is a member of the group AIC_HR already');
  end if;
  commit;
  -- the system user only for this block: the next statement in this session runs as nobody
  adm_context_api.clear_context;
exception
  when others then
    adm_context_api.clear_context;
    raise;
end;
/
set define off
set feedback on
