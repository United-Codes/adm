-- Lesson 7, the per-user identity: the same search as four APEX users, through
-- aic_app_tools_api.search_policies_as_app_user and aic_rag_bridge_api.search_passages_for_user.
-- Run as the APPLICATION schema (AIC_APP), after 24_aic_bridge_setup.sql and 27_aic_app_register.sql.
--
--   sql aic_app@<host>:<port>/<service> @29_aic_app_per_user.sql MY_ADMIN
--
-- MY_ADMIN is the ADM username of an active administrator of your ADM schema. AIC_APP cannot read
-- the ADM tables, so the script cannot look the name up (25_aic_bridge_check.sql, in the ADM
-- schema, does). To find one, run this in the ADM schema:
--   select min(u.username) from adm_users u join adm_roles r on r.role_id = u.role_id
--    where r.role_name = 'ADMIN' and u.is_active = 'Y';
-- Without the argument, the script skips the administrator row and says so.
--
-- Two search embeddings (the two refused users cause none). No answer model. Nothing is committed.
--
-- Each block creates an APEX session for one user name in the application of this schema, as a
-- sign-in would. The tool reads that user with sys_context('APEX$SESSION', 'APP_USER'). Note what
-- this shows about trust, too: code in this schema can create an APEX session for ANY name. The
-- name that the bridge receives is only as reliable as the code in this schema.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

-- &1 is optional: without an argument, aic_admin stays empty.
set define '&'
set verify off
set termout off
column 1 new_value 1
select '' as "1" from dual where 1 = 0;
set termout on
define aic_admin = '&1'
set verify off
set serveroutput on
set feedback off
set linesize 220

declare
  c_query constant varchar2(100 char) := '{"query":"salary band senior engineer"}';
  l_app_id    apex_applications.application_id%type;
  l_workspace apex_applications.workspace%type;
  l_message   varchar2(4000 char);
  c_admin     constant varchar2(255 char) := '&aic_admin';

  procedure ask_as (
    p_app_id    in number
  , p_apex_user in varchar2
  , p_message   out varchar2
  )
  as
    l_result clob;
    l_json   json_object_t;
  begin
    apex_session.create_session(p_app_id => p_app_id, p_page_id => 0, p_username => p_apex_user);
    l_result := aic_app_tools_api.search_policies_as_app_user(c_query);
    l_json   := json_object_t.parse(l_result);
    p_message := l_json.get_string('message');
    sys.dbms_output.put_line('APEX user ' || rpad(sys_context('APEX$SESSION', 'APP_USER'), 10)
                          || ' status: ' || l_json.get_string('status')
                          || ', searched_as: ' || nvl(l_json.get_string('searched_as'), '-'));
    if l_json.has('passages') then
      sys.dbms_output.put_line('                     passages: ' || json_query(l_result, '$.passages[*].document' with array wrapper));
    else
      sys.dbms_output.put_line('                     message:  ' || l_json.get_string('message'));
    end if;
    apex_session.delete_session;
  end ask_as;
begin
  select min(application_id) into l_app_id from apex_applications where owner = user;
  if l_app_id is null then
    raise_application_error(-20791, 'This schema has no APEX application. Run 22b_aic_app_application.sql, or create an application for this schema in the App Builder.');
  end if;
  select workspace into l_workspace from apex_applications where application_id = l_app_id;
  apex_util.set_workspace(l_workspace);

  sys.dbms_output.put_line('Question: ' || c_query);
  sys.dbms_output.put_line('ADM user of this session: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(none)'));
  ask_as(l_app_id, 'AIC_LEGAL', l_message);
  ask_as(l_app_id, 'AIC_HR', l_message);
  if c_admin is null then
    sys.dbms_output.put_line('APEX user (administrator) skipped: no ADM administrator was named. Run the script with the username as its argument.');
  else
    ask_as(l_app_id, c_admin, l_message);  -- an ADM administrator
    if l_message is null or l_message not like '%the user has the role ADMIN%' then
      sys.dbms_output.put_line('Note: the bridge did not refuse "' || c_admin || '" for its role. Name an active ADM user with the role ADMIN.');
    end if;
  end if;
  ask_as(l_app_id, 'J_DOE', l_message);    -- no ADM user has this name
  sys.dbms_output.put_line('ADM user of this session: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(none)'));
end;
/
set define off
set feedback on
