-- The question list through the agent. Run after 14_aic_questions.sql. Costs 10 agent runs
-- (about 1,000 to 4,000 tokens each, 5 to 15 seconds each).
--
--   sql -name <connection> @15_aic_agent_questions.sql             -- collections as they are
--   sql -name <connection> @15_aic_agent_questions.sql 0.4         -- default score threshold 0.4
--
-- For each question it runs the agent as the user in aic_questions.ask_as, reads the trace, and
-- reports four things:
--   retrieved  did a tool result contain the expected document?   (NA when no document is expected)
--   cited      does the answer name that document?
--   fact       does the answer contain the expected fact?          (regular expression)
--   tools      how many tool calls, and the tokens the run used
-- A question can be "retrieved" and still answered wrongly, and the other way round, which is why
-- these are separate columns.
--
-- With an argument the default_score_threshold of both collections is set for the run and put back
-- at the end.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

define aic_threshold = '&1'
set define on
set verify off
set serveroutput on
set feedback off
set linesize 220
alter session set nls_numeric_characters = '.,';

declare
  c_threshold constant varchar2(20 char) := '&aic_threshold';
  type t_orig_map is table of clob index by varchar2(30 char);
  l_orig_map    t_orig_map;
  l_result      json_object_t;
  l_t           timestamp;
  l_exec_id     number;
  l_answer      clob;
  l_docs        varchar2(1000 char);
  l_queries     varchar2(1000 char);
  l_retrieved   varchar2(10 char);
  l_cited       varchar2(10 char);
  l_fact        varchar2(10 char);
  l_in          number := 0;
  l_out         number := 0;
  l_secs        number := 0;
  l_tools       number := 0;
  l_n_ret       number := 0;
  l_n_cit       number := 0;
  l_n_fact      number := 0;
  l_n_exp       number := 0;
  l_secs_one    number;

  procedure set_threshold (
    p_on       in     boolean
  , pio_orig_map in out nocopy t_orig_map
  ) is
    l_cfg json_object_t;
  begin
    adm_context_api.system_login;
    <<collection_loop>>
    for c in (select rag_collection_id, collection_name, config_json from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if p_on then
        pio_orig_map(c.collection_name) := c.config_json;
        l_cfg := json_object_t.parse(c.config_json);
        l_cfg.put('default_score_threshold', to_number(c_threshold));
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => l_cfg.to_clob);
      else
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => pio_orig_map(c.collection_name));
      end if;
    end loop collection_loop;
    commit;
  end set_threshold;
begin
  if lower(c_threshold) != 'default' and c_threshold is not null then
    set_threshold(true, l_orig_map);
  end if;

  sys.dbms_output.put_line('default_score_threshold: ' || nvl(c_threshold, 'default (0.5)'));
  sys.dbms_output.put_line(rpad('Q', 3) || rpad('asked as', 11) || rpad('retrieved', 10) || rpad('cited', 7) || rpad('fact', 6)
    || rpad('tools', 6) || rpad('in', 7) || rpad('out', 6) || rpad('sec', 6) || 'search texts the model chose');
  <<question_loop>>
  for q in (select q_no, question, collection_name, expected_doc, expected_fact, ask_as from aic_questions order by q_no) loop
    l_t := systimestamp;
    l_result  := aic_agent_api.run_as(q.ask_as, 'aic_assistant', q.question);
    l_secs_one := round(extract(second from (systimestamp - l_t)) + 60 * extract(minute from (systimestamp - l_t)), 1);
    l_exec_id := l_result.get_number('execution_id');
    l_answer  := l_result.get_clob('final_message');

    select listagg(distinct d.document, ',') within group (order by d.document)
      into l_docs
      from uc_ai_agent_messages m
     cross apply json_table(m.tool_output, '$.passages[*]' columns (document varchar2(200 char) path '$.document')) d
     where m.execution_id = l_exec_id and m.role = 'tool_result';

    select listagg(json_value(m.tool_input, '$.query'), ' | ') within group (order by m.seq)
      into l_queries
      from uc_ai_agent_messages m
     where m.execution_id = l_exec_id and m.role = 'tool_call';

    if q.expected_doc is null then
      l_retrieved := 'NA';
    else
      l_retrieved := case when instr(nvl(l_docs, ' '), q.expected_doc) > 0 then 'yes' else 'NO' end;
      l_n_exp := l_n_exp + 1;
      if l_retrieved = 'yes' then l_n_ret := l_n_ret + 1; end if;
    end if;
    l_cited := case when q.expected_doc is null then 'NA'
                    when instr(lower(l_answer), lower(replace(q.expected_doc, '.pdf'))) > 0 then 'yes' else 'NO' end;
    if l_cited = 'yes' then l_n_cit := l_n_cit + 1; end if;
    l_fact := case when regexp_like(l_answer, q.expected_fact, 'i') then 'yes' else 'NO' end;
    if l_fact = 'yes' then l_n_fact := l_n_fact + 1; end if;

    l_in    := l_in  + l_result.get_object('usage').get_number('prompt_tokens');
    l_out   := l_out + l_result.get_object('usage').get_number('completion_tokens');
    l_tools := l_tools + l_result.get_number('tool_calls_count');
    l_secs  := l_secs + l_secs_one;

    sys.dbms_output.put_line(rpad(q.q_no, 3) || rpad(q.ask_as, 11) || rpad(l_retrieved, 10) || rpad(l_cited, 7) || rpad(l_fact, 6)
      || rpad(l_result.get_number('tool_calls_count'), 6)
      || rpad(l_result.get_object('usage').get_number('prompt_tokens'), 7)
      || rpad(l_result.get_object('usage').get_number('completion_tokens'), 6)
      || rpad(l_secs_one, 6) || l_queries);
    sys.dbms_output.put_line('     A: ' || replace(substr(l_answer, 1, 170), chr(10), ' '));
  end loop question_loop;

  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('retrieved ' || l_n_ret || ' of ' || l_n_exp || ', cited ' || l_n_cit || ' of ' || l_n_exp
    || ', fact right ' || l_n_fact || ' of 10');
  sys.dbms_output.put_line('total: ' || l_tools || ' tool calls, ' || l_in || ' tokens in, ' || l_out || ' tokens out, ' || round(l_secs) || ' s');

  if lower(c_threshold) != 'default' and c_threshold is not null then
    set_threshold(false, l_orig_map);
    sys.dbms_output.put_line('(default_score_threshold put back)');
  end if;
exception
  when others then
    if lower(c_threshold) != 'default' and c_threshold is not null and l_orig_map.count > 0 then
      set_threshold(false, l_orig_map);
    end if;
    raise;
end;
/
set feedback on
