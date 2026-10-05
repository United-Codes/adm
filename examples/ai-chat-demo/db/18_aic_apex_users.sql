-- Creates the two APEX accounts AIC_LEGAL and AIC_HR for the chat page (lesson 4).
-- Run as the ADM schema owner. Re-runnable: an account that exists is left alone.
--
--   sql -name <connection> @18_aic_apex_users.sql
--
-- DEMO PASSWORD, FOR A LOCAL SCHEMA ONLY. Both accounts get the password below. It is written in
-- this file, so everybody who has the file knows it. Never run this script against a database that
-- other people can reach. 99_aic_teardown.sql removes the two accounts again.
--
-- The chat page logs the user in with the APEX account. The ADM user of the same name (created
-- by 01_aic_users.sql) decides what that user may read. The page only opens for an APEX account
-- that also has an active ADM user. The accounts are created in the workspace of this schema,
-- found the same way as in 07_aic_agent_api.pkb. They are not developers or administrators and
-- need no email address.

set define '&'
define aic_demo_password = 'Aic-Demo-2026'
set serveroutput on
set verify off
set feedback off

declare
  l_workspace apex_workspaces.workspace%type;

  procedure say (
    p_text in varchar2
  )
  as
  begin
    sys.dbms_output.put_line(p_text); -- @dblinter ignore(g-5010): script output for the person who runs it
  end say;

  procedure ensure_apex_user (
    p_workspace in varchar2
  , p_username  in varchar2
  )
  as
  begin
    if apex_util.get_user_id(p_username => upper(p_username)) is null then
      apex_util.create_user(
        p_user_name                    => upper(p_username)
      , p_web_password                 => '&aic_demo_password.'
      , p_change_password_on_first_use => 'N'
      );
      say('  APEX account created: ' || upper(p_username) || ' (workspace ' || p_workspace || ')');
    else
      say('  APEX account exists:  ' || upper(p_username) || ' (workspace ' || p_workspace || ')');
    end if;
  end ensure_apex_user;
begin
  select min(workspace_name)
    into l_workspace
    from apex_workspace_schemas
   where schema = user;

  if l_workspace is null then
    say('  The schema ' || user || ' is not assigned to an APEX workspace. No account created.');
    return;
  end if;

  apex_util.set_workspace(l_workspace);
  ensure_apex_user(l_workspace, 'AIC_LEGAL');
  ensure_apex_user(l_workspace, 'AIC_HR');
  commit;
  say('  password of both accounts: &aic_demo_password.');
end;
/
set define off
set feedback on
