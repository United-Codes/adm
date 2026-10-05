-- Shows the trap behind aic_agent_api.run_as. Run it in a FRESH SQLcl session (the trap only
-- bites on the first execute_agent call of a database session). Costs one agent run.
--
--   sql -name <connection> @09_aic_identity_wipe.sql
--
-- The obvious way to run an agent as a user from SQL:
--   1. adm_context_api.system_user_login('AIC_LEGAL')
--   2. uc_ai_agents_api.execute_agent(...)
-- The user is in the context before the call and gone after it. The tool then finds no user,
-- returns status no_identity, and the agent tells you the search is not available.
-- Without the status check in the tool, ADM would return zero passages without an error and
-- the agent would say "nothing found", which looks like a permission result.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set long 4000
set feedback off
alter session set nls_numeric_characters = '.,';

declare
  l_result json_object_t;
  l_exec   number;
  l_ws     apex_workspaces.workspace%type;
begin
  select min(workspace_name) into l_ws from apex_workspace_schemas where schema = user;
  apex_util.set_workspace(l_ws);   -- needed for the web credential, nothing to do with identity

  adm_context_api.system_user_login('AIC_LEGAL');
  sys.dbms_output.put_line('context before execute_agent: ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(empty)'));

  l_result := uc_ai_agents_api.execute_agent(
    p_agent_code       => 'aic_assistant'
  , p_input_parameters => json_object_t('{"question":"What notice period applies to the Alpenwerk maintenance contract?"}')
  );

  sys.dbms_output.put_line('context after execute_agent:  ' || nvl(sys_context('ADM_CONTEXT', 'ADM_USERNAME'), '(empty)'));
  l_exec := l_result.get_number('execution_id');   -- a JSON object cannot be used inside SQL
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('Tool result the model saw:');
  <<result_loop>>
  for r in (
    select substr(m.tool_output, 1, 300) as tool_output
      from uc_ai_agent_messages m
     where m.execution_id = l_exec
       and m.role = 'tool_result'
     order by m.seq
  ) loop
    sys.dbms_output.put_line('  ' || r.tool_output);
  end loop result_loop;
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('Answer: ' || l_result.get_clob('final_message'));
  sys.dbms_output.put_line('Tokens: ' || l_result.get_object('usage').to_string);
end;
/
set feedback on
