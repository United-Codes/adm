-- The same questions as two users. Run it in a FRESH SQLcl session. Costs 4 agent runs (about
-- 1,000 to 3,000 tokens each) plus a few embedding calls for the search texts.
--
--   sql -name <connection> @12_aic_two_users.sql
--
--   AIC_LEGAL may read the Helios contract and not the salary bands.
--   AIC_HR    may read the salary bands and not the Helios contract.
-- Both are ordinary users (role CONTRIBUTOR). An administrator would see everything.
--
-- Part A  The tool function, called directly as each user: no agent, no model. This is the
--         deterministic proof that the filter is in the database and not in the prompt.
-- Part B  The same call with p_limit => 1 and 2: "nothing found" because of recall, not permission.
-- Part C  The same questions through the agent, as each user.

set define off
set serveroutput on
set long 4000
set feedback off
alter session set nls_numeric_characters = '.,';
set linesize 220

-- Part A and B -------------------------------------------------------------------------------
prompt
prompt === Part A: the same search, called as each user (no agent) ===
declare
  procedure show (
    p_user       in varchar2
  , p_collection in varchar2
  , p_query      in varchar2
  , p_limit      in number default null
  , p_threshold  in number default null
  )
  as
    l_out    clob;
    l_status varchar2(30 char);
    l_docs   varchar2(1000 char);
  begin
    adm_context_api.system_user_login(p_user);
    l_out := aic_rag_tools_api.search(p_collection, p_query, p_limit => p_limit, p_score_threshold => p_threshold);
    select json_value(l_out, '$.status') into l_status from dual;
    select listagg(d.document || ' (' || d.score || ')', ', ') within group (order by d.score desc)
      into l_docs
      from json_table(l_out, '$.passages[*]' columns (document varchar2(200) path '$.document', score number path '$.score')) d;
    dbms_output.put_line(rpad(p_user, 10) || ' limit ' || rpad(nvl(to_char(p_limit), 'default'), 8) || ' threshold ' || rpad(nvl(to_char(p_threshold), 'default'), 8) || ' -> ' || rpad(l_status, 12) || nvl(l_docs, ''));
  end show;
begin
  show('AIC_LEGAL', 'aic_contracts', 'Helios exclusive distribution notice period twelve months');
  show('AIC_HR',    'aic_contracts', 'Helios exclusive distribution notice period twelve months');
  show('AIC_HR',    'aic_policies',  'salary band senior engineer');
  show('AIC_LEGAL', 'aic_policies',  'salary band senior engineer');

  dbms_output.put_line('');
  dbms_output.put_line('=== Part B: p_limit. The vector search returns the top k chunks, THEN the access filter runs ===');
  dbms_output.put_line('(query "exclusive distribution Austria Switzerland": the two best chunks are both from the Helios contract)');
  show('AIC_LEGAL', 'aic_contracts', 'exclusive distribution Austria Switzerland', 1, 0.3);
  show('AIC_HR',    'aic_contracts', 'exclusive distribution Austria Switzerland', 1, 0.3);
  show('AIC_HR',    'aic_contracts', 'exclusive distribution Austria Switzerland', 2, 0.3);
  show('AIC_HR',    'aic_contracts', 'exclusive distribution Austria Switzerland', 3, 0.3);
  show('AIC_HR',    'aic_contracts', 'exclusive distribution Austria Switzerland', 20, 0.3);
end;
/

-- Part C -------------------------------------------------------------------------------------
prompt
prompt === Part C: the same questions through the agent ===
declare
  l_result json_object_t;
  l_t      timestamp;

  procedure ask (
    p_user     in varchar2
  , p_question in varchar2
  )
  as
  begin
    l_t := systimestamp;
    l_result := aic_agent_api.run_as(p_user, 'aic_assistant', p_question);
    dbms_output.put_line('--- as ' || p_user);
    dbms_output.put_line('Q: ' || p_question);
    dbms_output.put_line('A: ' || l_result.get_clob('final_message'));
    dbms_output.put_line('   tool calls ' || l_result.get_number('tool_calls_count')
      || ', tokens ' || l_result.get_object('usage').get_number('prompt_tokens')
      || ' in / ' || l_result.get_object('usage').get_number('completion_tokens')
      || ' out, ' || round(extract(second from (systimestamp - l_t)), 1) || ' s');
    dbms_output.put_line('');
  end ask;
begin
  ask('AIC_LEGAL', 'What notice period applies to the Helios distribution agreement?');
  ask('AIC_HR',    'What notice period applies to the Helios distribution agreement?');
  ask('AIC_HR',    'Which salary band is a senior engineer in?');
  ask('AIC_LEGAL', 'Which salary band is a senior engineer in?');
end;
/
set feedback on
