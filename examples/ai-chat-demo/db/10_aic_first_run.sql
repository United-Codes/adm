-- The first agent run, as the Legal user, with the identity fix. run_as creates the APEX session itself, so any session works.
-- Costs one agent run (about 1,200 tokens, 5 to 10 seconds).
--
--   sql -name <connection> @10_aic_first_run.sql
--
-- aic_agent_api.run_as creates the APEX session first, then the ADM context, then runs the agent.
-- It is a demo helper for running an agent from plain SQL. See the header of 07_aic_agent_api.pks
-- for why it is an exception and what the normal paths are.
--
-- What to look at in the output:
--   * "searched_as" in the tool result is sys_context('ADM_CONTEXT', 'ADM_USERNAME') read INSIDE
--     the tool, while the model was running. It must say AIC_LEGAL. If it is missing, or the
--     status is no_identity, the context was lost and the answer means nothing.
--   * The answer quotes the clause and names the document (the citation rule of the profile).

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set long 4000
set feedback off
alter session set nls_numeric_characters = '.,';
set linesize 220

declare
  l_result  json_object_t;
  l_started timestamp := systimestamp;
begin
  l_result := aic_agent_api.run_as(
    p_username   => 'AIC_LEGAL'
  , p_agent_code => 'aic_assistant'
  , p_question   => 'What notice period applies to the Alpenwerk maintenance contract?'
  );

  sys.dbms_output.put_line('Answer:');
  sys.dbms_output.put_line(l_result.get_clob('final_message'));
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('Tool calls:   ' || l_result.get_number('tool_calls_count'));
  sys.dbms_output.put_line('Tokens:       ' || l_result.get_object('usage').to_string);
  sys.dbms_output.put_line('Seconds:      ' || round(extract(second from (systimestamp - l_started)), 1));
  sys.dbms_output.put_line('Context after the run: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(empty)'));
  sys.dbms_output.put_line('Execution id: ' || l_result.get_number('execution_id') || '   session id: ' || l_result.get_string('session_id'));
end;
/

prompt
prompt What the model asked for and what the tool answered (the trace):
col seq        format 999
col role       format a12
col tool_name  format a22
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
 where m.execution_id = (select max(e.id) from uc_ai_agent_executions e where e.agent_id = (select a.id from uc_ai_agents a where a.code = 'aic_assistant'))
 order by m.seq;
set feedback on
