-- Lesson 7: search from the application schema, first by hand and then through its agent. Run as the
-- APPLICATION schema (AIC_APP), after 27_aic_app_register.sql. Any session works.
--
--   sql aic_app@<host>:<port>/<service> @28_aic_app_run.sql
--
-- Three direct tool calls (three search embeddings, no model), then one agent run on gpt-6.1-sol
-- (about 2,000 to 4,000 input tokens), then the trace of that run from uc_ai_agent_messages of THIS
-- schema. The ADM schema has its own UC AI tables; this run does not appear in them.
--
-- This schema has no ADM user and cannot set one: it has no grant on adm_context_api. The tools
-- search through the bridge, which searches as AIC_SERVICE.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set long 4000
set feedback off
set linesize 220
alter session set nls_numeric_characters = '.,';

prompt === The tools, called directly ===
declare
  procedure show (
    p_label  in varchar2
  , p_result in clob
  )
  as
    l_json json_object_t;
  begin
    l_json := json_object_t.parse(p_result);
    sys.dbms_output.put_line(p_label);
    sys.dbms_output.put_line('  status:      ' || l_json.get_string('status') || ', searched_as: ' || l_json.get_string('searched_as'));
    if l_json.has('passages') then
      sys.dbms_output.put_line('  passages:    ' || json_query(p_result, '$.passages[*].document' with array wrapper));
    else
      sys.dbms_output.put_line('  message:     ' || l_json.get_string('message'));
    end if;
  end show;
begin
  sys.dbms_output.put_line('ADM user of this session: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(none)'));
  show('search_contracts, "Alpenwerk notice period termination"'
     , aic_app_tools_api.search_contracts('{"query":"Alpenwerk notice period termination"}'));
  show('search_policies, "salary band senior engineer"'
     , aic_app_tools_api.search_policies('{"query":"salary band senior engineer"}'));
  show('search(''aic_handbook''), a collection that does not exist'
     , aic_app_tools_api.search('aic_handbook', 'notice period'));
  sys.dbms_output.put_line('ADM user of this session: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(none)'));
end;
/

prompt
prompt === The agent run ===
declare
  l_workspace apex_workspaces.workspace%type;
  l_app_id    apex_applications.application_id%type;
  l_result    json_object_t;
  l_started   timestamp := systimestamp;
begin
  -- UC AI runs the code of a tool in the parsing schema of the APEX application of the session.
  -- With no APEX session, execute_agent creates one in ANY application of the workspace, which can
  -- belong to the ADM schema. So create the session in an application of THIS schema first.
  select min(application_id) into l_app_id from apex_applications where owner = user;
  if l_app_id is null then
    raise_application_error(-20791, 'This schema has no APEX application. Run 22b_aic_app_application.sql, or create an application for this schema in the App Builder.');
  end if;
  select workspace into l_workspace from apex_applications where application_id = l_app_id;
  apex_util.set_workspace(l_workspace);
  apex_session.create_session(p_app_id => l_app_id, p_page_id => 0, p_username => 'AIC_APP_DEMO');

  l_result := uc_ai_agents_api.execute_agent(
    p_agent_code       => 'aic_app_assistant'
  , p_input_parameters => json_object_t('{"question":"How do we end the Alpenwerk maintenance contract, and what may I spend on a hotel when I visit them?"}')
  , p_session_id       => uc_ai_agents_api.generate_session_id
  );

  sys.dbms_output.put_line('Answer:');
  sys.dbms_output.put_line(l_result.get_clob('final_message'));
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('Tool calls:   ' || l_result.get_number('tool_calls_count'));
  sys.dbms_output.put_line('Tokens:       ' || l_result.get_object('usage').to_string);
  sys.dbms_output.put_line('Seconds:      ' || round(extract(second from (systimestamp - l_started)), 1));
  sys.dbms_output.put_line('Execution id: ' || l_result.get_number('execution_id'));
  apex_session.delete_session;
end;
/

prompt
prompt === The trace of the run, from uc_ai_agent_messages of this schema ===
col seq        format 999
col role       format a12
col tool_name  format a24
col what       format a150 word_wrapped
select m.seq
     , m.role
     , m.tool_name
     , case m.role
         when 'tool_call'   then m.tool_input
         when 'tool_result' then substr(m.tool_output, 1, 140) || ' ...'
         else substr(m.content, 1, 140)
       end as what
  from uc_ai_agent_messages m
 where m.execution_id = (select max(e.id) from uc_ai_agent_executions e where e.agent_id = (select a.id from uc_ai_agents a where a.code = 'aic_app_assistant'))
 order by m.seq;

prompt
prompt === Who ran it ===
col status       format a10
col db_user      format a10
col apex_user    format a16
select e.id, e.status, e.db_user, e.apex_user, e.apex_app_id, e.tool_calls_count, e.total_input_tokens, e.total_output_tokens
  from uc_ai_agent_executions e
 where e.id = (select max(x.id) from uc_ai_agent_executions x where x.agent_id = (select a.id from uc_ai_agents a where a.code = 'aic_app_assistant'));
set feedback on
