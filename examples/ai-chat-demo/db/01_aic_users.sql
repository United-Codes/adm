-- Step 1 of 7: two ADM users with different access, and the two groups that own the folders.
-- Run as the ADM schema owner. Re-runnable: what exists is left alone.
--
--   AIC_LEGAL  member of group AIC_LEGAL  -> sees /groups/aic_legal (all contracts)
--   AIC_HR     member of group AIC_HR     -> sees /groups/aic_hr (all policies)
--
-- Both users have the role CONTRIBUTOR. They are NOT administrators: an administrator
-- passes every access check, so a demo of access control needs ordinary users.
--
-- The chat page needs more than this (phase 2): the same user names must also exist as APEX
-- accounts of the workspace that runs the page, because the page logs the user in. These
-- scripts work without that, because they act as the ADM user with
-- adm_context_api.system_user_login.

set define off
set serveroutput on
set feedback off

declare
  l_role_id  adm_roles.role_id%type;
  l_group_id adm_groups.group_id%type;
  l_user_id  adm_users.user_id%type;

  procedure ensure_user (
    p_username in varchar2
  )
  as
    l_count number;
  begin
    select count(*) into l_count from adm_users where username = upper(p_username);
    if l_count = 0 then
      adm_user_api.add_user(p_username => p_username, p_role_id => l_role_id);
      dbms_output.put_line('  user created:  ' || upper(p_username));
    else
      dbms_output.put_line('  user exists:   ' || upper(p_username));
    end if;
  end ensure_user;

  procedure ensure_group (
    p_group_name  in varchar2
  , p_description in varchar2
  , p_username    in varchar2
  )
  as
    l_count number;
  begin
    select count(*) into l_count from adm_groups where group_name = upper(p_group_name);
    if l_count = 0 then
      adm_group_api.create_group(p_group_name => p_group_name, p_description => p_description, po_group_id => l_group_id);
      dbms_output.put_line('  group created: ' || upper(p_group_name));
    else
      select group_id into l_group_id from adm_groups where group_name = upper(p_group_name);
      dbms_output.put_line('  group exists:  ' || upper(p_group_name));
    end if;

    select user_id into l_user_id from adm_users where username = upper(p_username);
    select count(*)
      into l_count
      from adm_group_members
     where group_id = l_group_id
       and user_id  = l_user_id;
    if l_count = 0 then
      adm_group_api.add_user_to_group(p_group_id => l_group_id, p_user_id => l_user_id);
    end if;
  end ensure_group;
begin
  adm_context_api.system_login;

  select role_id into l_role_id from adm_roles where role_name = 'CONTRIBUTOR';

  ensure_user('AIC_LEGAL');
  ensure_user('AIC_HR');
  ensure_group('AIC_LEGAL', 'Demo: legal department, owns the contracts', 'AIC_LEGAL');
  ensure_group('AIC_HR',    'Demo: HR department, owns the policies',     'AIC_HR');
  commit;
end;
/
set feedback on
