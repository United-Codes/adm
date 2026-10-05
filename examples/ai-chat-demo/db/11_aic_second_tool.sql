-- The follow-up the first tool cannot answer, then the second tool. Run it in a FRESH SQLcl
-- session. Costs three agent runs (about 1,000 to 4,000 tokens each).
--
--   sql -name <connection> @11_aic_second_tool.sql
--
--   1. Ask a contract question, then a follow-up about the travel policy, in ONE conversation
--      (same session id). The agent has only AIC_SEARCH_CONTRACTS, so the policy is out of reach.
--   2. Register AIC_SEARCH_POLICIES with the SAME tag. The profile is not touched: it selects
--      tools by the tag aic_demo, so the new tool is available on the next run.
--   3. Ask the follow-up again in the same conversation.
--
-- Everything runs as AIC_LEGAL. Legal may read both the contracts and the policies except the
-- salary bands.

set define off
set serveroutput on
set long 4000
set feedback off
alter session set nls_numeric_characters = '.,';
set linesize 220

declare
  l_result  json_object_t;
  l_session varchar2(100 char);
  l_t       timestamp;
  l_tool_id uc_ai_tools.id%type;

  procedure ask (
    p_label    in varchar2
  , p_question in varchar2
  )
  as
  begin
    l_t := systimestamp;
    l_result := aic_agent_api.run_as('AIC_LEGAL', 'aic_assistant', p_question, l_session);
    l_session := l_result.get_string('session_id');
    dbms_output.put_line('--- ' || p_label);
    dbms_output.put_line('Q: ' || p_question);
    dbms_output.put_line('A: ' || l_result.get_clob('final_message'));
    dbms_output.put_line('   tool calls ' || l_result.get_number('tool_calls_count')
      || ', tokens ' || l_result.get_object('usage').get_number('prompt_tokens')
      || ' in / ' || l_result.get_object('usage').get_number('completion_tokens')
      || ' out, ' || round(extract(second from (systimestamp - l_t)), 1) || ' s');
    dbms_output.put_line('');
  end ask;
begin
  -- back to the first state, in case this script ran before
  delete from uc_ai_tools where code = 'AIC_SEARCH_POLICIES';
  commit;

  l_session := uc_ai_agents_api.generate_session_id;

  ask('1a. a contract question', 'What notice period applies to the Alpenwerk maintenance contract?');
  ask('1b. the follow-up: one tool', 'And what does our travel policy say about hotel costs?');

  -- 2. the second tool, same tag
  l_tool_id := uc_ai_tools_api.merge_tool_from_schema(
    p_tool_code     => 'AIC_SEARCH_POLICIES'
  , p_description   => 'Search the internal policies of the company (travel policy in all its versions, remote '
                    || 'work, employee handbook, salary bands). Returns the best matching passages with the '
                    || 'name of the document. Use it for questions about what employees may or must do: '
                    || 'travel costs, vacation, working hours, remote work, notice periods of employees. '
                    || 'Policies exist in several versions; look at the validity dates. Use short queries made '
                    || 'of the key words, for example "hotel limit per night".'
  , p_function_call => 'return aic_rag_tools_api.search_policies(:parameters);'
  , p_json_schema   => json_object_t('{
      "type": "object",
      "properties": {
        "query":       { "type": "string", "description": "What to look for. Key words, not a whole sentence." },
        "max_sources": { "type": "number", "description": "How many documents at most. Default 5." }
      },
      "required": ["query"]
    }')
  , p_tags          => apex_t_varchar2('aic_demo')
  , p_code_mode_access => 'direct'
  );
  commit;
  dbms_output.put_line('(registered AIC_SEARCH_POLICIES with the tag aic_demo; the profile was not changed)');
  dbms_output.put_line('');

  -- 3. the same follow-up, same conversation
  ask('3. the follow-up again: two tools', 'And what does our travel policy say about hotel costs?');
end;
/

prompt
prompt Tool calls of this conversation (status is always success, even when the tool returned no_passages or an error: read tool_output):
col seq       format 999
col tool_name format a22
col tool_input format a70
col tool_status format a12
col result_status format a28
select c.seq
     , c.tool_name
     , c.tool_input
     , r.tool_status
     , substr(regexp_substr(r.tool_output, '"status":"[a-z_]+"'), 1, 30) as result_status
  from uc_ai_agent_messages c
  join uc_ai_agent_messages r
    on r.execution_id = c.execution_id
   and r.role         = 'tool_result'
   and r.seq          = c.seq + 1
 where c.role = 'tool_call'
   and c.session_id = (select max(session_id) keep (dense_rank last order by started_at)
                         from uc_ai_agent_executions
                        where agent_id = (select id from uc_ai_agents where code = 'aic_assistant'))
 order by c.execution_id, c.seq;
set feedback on
