-- Lesson 6: how the search settings of a collection change what the agent gets and what it costs.
-- Run as the ADM schema owner, after 14_aic_questions.sql (it reads the table aic_questions).
--
--   sql -name <connection> @20_aic_config_matrix.sql           -- all three parts
--   sql -name <connection> @20_aic_config_matrix.sql search    -- parts 1 and 2 only, no agent runs
--
-- Model spend:
--   parts 1 and 2   no answer model. About 80 search embeddings (a few thousand tokens in all).
--   part 3          30 agent runs on gpt-6.1-sol: the question list three times. In the recordings
--                   about 45,000 input and 3,500 output tokens, and 10 to 12 calls of the rewrite
--                   model for the third list, which the token figures of the agent do not include.
--                   About 3 to 4 minutes.
--
-- The parts:
--   1. Measure one search per question. Calls the search tool of the agent once for each question,
--      with the question as the search text, under seven settings. The last row passes
--      "max_sources": 5 in the tool parameters, as the model did before
--      21_aic_tools_without_max_sources.sql. Prints how many expected documents and facts reached
--      the result, and its size in characters.
--   2. Compare the chunk sizes. Only if the collection aic_policies_large exists (lesson 6 creates it
--      in the RAG collection manager): the best score of the expected document in aic_policies
--      (chunks of 700 characters) and in aic_policies_large (the default chunk size).
--   3. Run the question list through the agent, three times: the stored settings, no surrounding
--      chunks, and query rewriting on. Scores each answer the way 15_aic_agent_questions.sql does.
--
-- Each row sets default_max_sources, default_surrounding_chunks and query_rewriting.enabled on both
-- collections explicitly, so that the result does not depend on what is stored. The score thresholds
-- stay as stored (0.4 for aic_policies after lesson 6, 0.5 for aic_contracts), except in the rows
-- that name a threshold. The script puts the stored configuration back at the end of each part,
-- also after an error.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

-- An empty &1 when the script is called without an argument, instead of a prompt.
set termout off
column 1 new_value 1
select null as "1" from dual where rownum = 0; -- @dblinter ignore(g-2180): SQLcl names the substitution variable 1 after this column
set termout on
define aic_part = '&1'

set define on
set verify off
set serveroutput on
set feedback off
set linesize 220
alter session set nls_numeric_characters = '.,';

-- ---------------------------------------------------------------------------
-- Measure one search per question
-- ---------------------------------------------------------------------------
declare
  type t_config_map is table of clob index by varchar2(30 char);
  l_stored_map t_config_map;

  -- Sets the search defaults of both collections for one row. A null threshold keeps the stored one.
  -- The first call keeps the stored configuration in pio_stored_map.
  procedure set_defaults (
    pio_stored_map in out nocopy t_config_map
  , p_max_sources  in number
  , p_surrounding  in number
  , p_threshold    in number default null
  ) is
    l_cfg     json_object_t;
    l_rewrite json_object_t;
  begin
    adm_context_api.system_login;
    <<collection_loop>>
    for c in (select rag_collection_id, collection_name, config_json from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if not pio_stored_map.exists(c.collection_name) then
        pio_stored_map(c.collection_name) := c.config_json;
      end if;
      l_cfg := json_object_t.parse(pio_stored_map(c.collection_name));
      l_cfg.put('default_max_sources', p_max_sources);
      l_cfg.put('default_surrounding_chunks', p_surrounding);
      if p_threshold is not null then
        l_cfg.put('default_score_threshold', p_threshold);
      end if;
      if l_cfg.has('query_rewriting') then
        l_rewrite := l_cfg.get_object('query_rewriting');
        l_rewrite.put('enabled', false);
        l_cfg.put('query_rewriting', l_rewrite);
      end if;
      adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => l_cfg.to_clob);
    end loop collection_loop;
    commit;
    adm_context_api.clear_context;
  exception
    when others then
      adm_context_api.clear_context;
      raise;
  end set_defaults;

  procedure restore_stored (
    p_stored_map in t_config_map
  ) is
  begin
    adm_context_api.system_login;
    <<collection_loop>>
    for c in (select rag_collection_id, collection_name from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if p_stored_map.exists(c.collection_name) then
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => p_stored_map(c.collection_name));
      end if;
    end loop collection_loop;
    commit;
    adm_context_api.clear_context;
  exception
    when others then
      adm_context_api.clear_context;
      raise;
  end restore_stored;

  -- One row of the table: every question once, through the tool function the agent calls.
  procedure measure (
    p_label       in varchar2
  , p_max_sources in number
  , p_surrounding in number
  , p_threshold   in number default null
  , p_ask_for     in number default null
  ) is
    l_params  json_object_t;
    l_out     clob;
    l_docs    pls_integer;
    l_found   pls_integer := 0;
    l_facts   pls_integer := 0;
    l_noans   pls_integer := 0;
    l_total   pls_integer := 0;
    l_chars   pls_integer := 0;
    l_largest pls_integer := 0;
    l_missing varchar2(100 char);
  begin
    set_defaults(l_stored_map, p_max_sources, p_surrounding, p_threshold); -- @dblinter ignore(g-7130): the one map of this block, which restore_stored needs after every row
    <<question_loop>>
    for q in (select q_no, question, collection_name, expected_doc, expected_fact, ask_as from aic_questions order by q_no) loop
      adm_context_api.system_user_login(q.ask_as);
      l_params := json_object_t();
      l_params.put('query', q.question);
      if p_ask_for is not null then
        l_params.put('max_sources', p_ask_for);
      end if;
      l_out := case q.collection_name
                 when 'aic_contracts' then aic_rag_tools_api.search_contracts(l_params.to_clob)
                 else aic_rag_tools_api.search_policies(l_params.to_clob)
               end;
      select count(*)
        into l_docs
        from json_table(l_out, '$.passages[*]' columns (document varchar2(200 char) path '$.document'));
      l_total   := l_total + l_docs;
      l_chars   := l_chars + sys.dbms_lob.getlength(l_out);
      l_largest := greatest(l_largest, sys.dbms_lob.getlength(l_out));
      if q.expected_doc is null then
        l_noans := l_noans + l_docs;
      else
        if instr(l_out, '"document":"' || q.expected_doc || '"') > 0 then
          l_found := l_found + 1;
        end if;
        -- the fact in the text of the result: the passage with the answer reached the model
        if regexp_like(l_out, q.expected_fact, 'i') then
          l_facts := l_facts + 1;
        else
          l_missing := l_missing || ' Q' || q.q_no;
        end if;
      end if;
    end loop question_loop;
    sys.dbms_output.put_line(rpad(p_label, 34) || rpad(l_found || '/9', 7) || rpad(l_facts || '/9', 7) || rpad(l_noans, 8)
      || rpad(l_total, 6) || rpad(l_chars, 8) || rpad(l_largest, 9) || nvl(trim(l_missing), '-'));
  end measure;

  -- The words the model chose for question 8 in the recordings, at two settings
  procedure model_words (
    p_surrounding in number
  ) is
    l_out clob;
  begin
    set_defaults(l_stored_map, 5, p_surrounding); -- @dblinter ignore(g-7130): the one map of this block, which restore_stored needs after every row
    adm_context_api.system_user_login('AIC_LEGAL');
    l_out := aic_rag_tools_api.search_contracts('{"query":"Helios distribution liability cap"}');
    sys.dbms_output.put_line('surrounding chunks ' || p_surrounding || ': '
      || json_value(l_out, '$.passages[0].matched_chunks') || ' matched chunk(s), '
      || sys.dbms_lob.getlength(l_out) || ' characters, liability cap EUR 2,000,000 in the result: '
      || case when instr(l_out, '2,000,000') > 0 then 'yes' else 'NO' end);
  end model_words;
begin
  sys.dbms_output.put_line('=== 1. One search per question, with the question as the search text ===');
  <<threshold_loop>>
  for c in (select collection_name, json_value(config_json, '$.default_score_threshold') as threshold
              from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies') order by collection_name) loop
    sys.dbms_output.put_line('stored default_score_threshold ' || rpad(c.collection_name, 14) || ': ' || c.threshold);
  end loop threshold_loop;
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line(rpad('setting', 34) || rpad('found', 7) || rpad('fact', 7) || rpad('Q10', 8)
    || rpad('docs', 6) || rpad('chars', 8) || rpad('largest', 9) || 'fact missing in');
  measure('5 sources, 1 surrounding (stored)', 5, 1);
  measure('5 sources, 0 surrounding',          5, 0);
  measure('5 sources, 2 surrounding',          5, 2);
  measure('1 source,  1 surrounding',          1, 1);
  measure('threshold 0.2, 5 sources',          5, 1, 0.2);
  measure('threshold 0.2, 2 sources',          2, 1, 0.2);
  measure('threshold 0.2, 2 sources, asks 5',  2, 1, 0.2, 5);

  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('Search with the words the model chose for question 8:');
  model_words(1);
  model_words(0);

  restore_stored(l_stored_map);
  sys.dbms_output.put_line('(stored configuration put back)');
exception
  when others then
    restore_stored(l_stored_map);
    raise;
end;
/

-- ---------------------------------------------------------------------------
-- Compare the chunk sizes
-- ---------------------------------------------------------------------------
declare
  l_large  number;
  l_chunks pls_integer;

  -- rank and best chunk score of the expected document, at threshold 0 so that a low score shows,
  -- and without query rewriting, so that a stored rewrite setting does not change the comparison
  function best (
    p_collection in varchar2
  , p_q          in aic_questions%rowtype
  ) return varchar2
  is
    l_id    adm_ai_rag_collections.rag_collection_id%type;
    l_rank  pls_integer;
    l_score number;
  begin
    select rag_collection_id into l_id from adm_ai_rag_collections where collection_name = p_collection;
    adm_context_api.system_user_login(p_q.ask_as);
    select min(rn)
         , min(score)
      into l_rank
         , l_score
      from (select document_name
                 , max(score) as score
                 , row_number() over (order by max(score) desc) as rn
              from table(adm_ai_rag_api.search_chunks(p_rag_collection_id => l_id, p_query => p_q.question, p_score_threshold => 0
                                                       , p_rewrite_query => false))
             group by document_name)
     where document_name = p_q.expected_doc;
    return case when l_rank is null then 'MISS' else '#' || l_rank || ' ' || to_char(l_score, 'FM0.000') end;
  end best;
begin
  select case when exists (select 1 from adm_ai_rag_collections c where c.collection_name = 'aic_policies_large') then 1 else 0 end
    into l_large
    from dual;
  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('=== 2. Chunk size: aic_policies (700 characters) and aic_policies_large (the defaults) ===');
  if l_large = 0 then
    sys.dbms_output.put_line('aic_policies_large does not exist. Create it as lesson 6 shows, then run this part again.');
  else
    <<collection_loop>>
    for c in (select collection_name, rag_collection_id from adm_ai_rag_collections
               where collection_name in ('aic_policies', 'aic_policies_large') order by collection_name) loop
      select count(*)
        into l_chunks
        from adm_ai_rag_chunks ch
        join adm_ai_rag_collection_files f on f.rag_collection_file_id = ch.rag_collection_file_id
       where f.rag_collection_id = c.rag_collection_id
         and f.is_active = 'Y';
      sys.dbms_output.put_line(rpad(c.collection_name, 20) || l_chunks || ' chunks');
    end loop collection_loop;
    sys.dbms_output.put_line(null);
    sys.dbms_output.put_line(rpad('Q', 4) || rpad('expected document', 26) || rpad('aic_policies', 16) || 'aic_policies_large');
    <<question_loop>>
    for q in (select q_no, question, collection_name, expected_doc, expected_fact, ask_as
                from aic_questions
               where collection_name = 'aic_policies'
                 and expected_doc is not null
               order by q_no) loop
      sys.dbms_output.put_line(rpad(q.q_no, 4) || rpad(q.expected_doc, 26) || rpad(best('aic_policies', q), 16) || best('aic_policies_large', q));
    end loop question_loop;
  end if;
end;
/

-- ---------------------------------------------------------------------------
-- Run the question list through the agent
-- ---------------------------------------------------------------------------
declare
  c_part constant varchar2(20 char) := '&aic_part';
  type t_config_map is table of clob index by varchar2(30 char);
  l_stored_map t_config_map;

  -- Sets the search defaults of both collections for one list. The first call keeps the stored
  -- configuration in pio_stored_map.
  procedure set_defaults (
    pio_stored_map in out nocopy t_config_map
  , p_surrounding  in number
  , p_rewrite      in boolean
  ) is
    l_cfg     json_object_t;
    l_rewrite json_object_t;
  begin
    adm_context_api.system_login;
    <<collection_loop>>
    for c in (select rag_collection_id, collection_name, config_json from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if not pio_stored_map.exists(c.collection_name) then
        pio_stored_map(c.collection_name) := c.config_json;
      end if;
      l_cfg := json_object_t.parse(pio_stored_map(c.collection_name));
      l_cfg.put('default_max_sources', 5);
      l_cfg.put('default_surrounding_chunks', p_surrounding);
      if p_rewrite then
        l_cfg.put('query_rewriting', json_object_t('{"enabled": true, "provider": "openai", "model": "gpt-6.1-sol", "config": {"g_apex_web_credential": "OPENAI"}}'));
      elsif l_cfg.has('query_rewriting') then
        l_rewrite := l_cfg.get_object('query_rewriting');
        l_rewrite.put('enabled', false);
        l_cfg.put('query_rewriting', l_rewrite);
      end if;
      adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => l_cfg.to_clob);
    end loop collection_loop;
    commit;
    adm_context_api.clear_context;
  exception
    when others then
      adm_context_api.clear_context;
      raise;
  end set_defaults;

  procedure restore_stored (
    p_stored_map in t_config_map
  ) is
  begin
    adm_context_api.system_login;
    <<collection_loop>>
    for c in (select rag_collection_id, collection_name from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if p_stored_map.exists(c.collection_name) then
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => p_stored_map(c.collection_name));
      end if;
    end loop collection_loop;
    commit;
    adm_context_api.clear_context;
  exception
    when others then
      adm_context_api.clear_context;
      raise;
  end restore_stored;

  -- The question list once, scored like 15_aic_agent_questions.sql, as one row of the table
  procedure run_list (
    p_label       in varchar2
  , p_surrounding in number
  , p_rewrite     in boolean
  ) is
    l_result    json_object_t;
    l_exec_id   number;
    l_answer    clob;
    l_docs      varchar2(1000 char);
    l_sent      varchar2(100 char);
    l_results   pls_integer;
    l_res_chars pls_integer;
    l_n_ret     pls_integer := 0;
    l_n_fact    pls_integer := 0;
    l_calls     pls_integer := 0;
    l_n_res     pls_integer := 0;
    l_chars     pls_integer := 0;
    l_in        pls_integer := 0;
    l_sent_all  varchar2(100 char);
    l_grid      varchar2(200 char);
    l_t         timestamp := systimestamp;
  begin
    set_defaults(l_stored_map, p_surrounding, p_rewrite); -- @dblinter ignore(g-7130): the one map of this block, which restore_stored needs after every row
    <<question_loop>>
    for q in (select q_no, question, expected_doc, expected_fact, ask_as from aic_questions order by q_no) loop
      l_result  := aic_agent_api.run_as(q.ask_as, 'aic_assistant', q.question);
      l_exec_id := l_result.get_number('execution_id');
      l_answer  := l_result.get_clob('final_message');

      select listagg(distinct d.document, ',') within group (order by d.document)
        into l_docs
        from uc_ai_agent_messages m
       cross apply json_table(m.tool_output, '$.passages[*]' columns (document varchar2(200 char) path '$.document')) d
       where m.execution_id = l_exec_id
         and m.role = 'tool_result';

      select count(*)
           , nvl(sum(sys.dbms_lob.getlength(m.tool_output)), 0)
        into l_results
           , l_res_chars
        from uc_ai_agent_messages m
       where m.execution_id = l_exec_id
         and m.role = 'tool_result';

      select listagg(distinct nvl(json_value(m.tool_input, '$.max_sources'), 'none'), ',') within group (order by nvl(json_value(m.tool_input, '$.max_sources'), 'none'))
        into l_sent
        from uc_ai_agent_messages m
       where m.execution_id = l_exec_id
         and m.role = 'tool_call';
      if l_sent is not null and instr(',' || l_sent_all || ',', ',' || l_sent || ',') = 0 then
        l_sent_all := ltrim(l_sent_all || ',' || l_sent, ',');
      end if;

      if q.expected_doc is not null and instr(nvl(l_docs, ' '), q.expected_doc) > 0 then
        l_n_ret := l_n_ret + 1;
      end if;
      if regexp_like(l_answer, q.expected_fact, 'i') then
        l_n_fact := l_n_fact + 1;
      end if;
      l_calls := l_calls + l_result.get_number('tool_calls_count');
      l_n_res := l_n_res + l_results;
      l_chars := l_chars + l_res_chars;
      l_in    := l_in + l_result.get_object('usage').get_number('prompt_tokens');
      -- one cell per question: the tool calls, and + when the answer has the fact
      l_grid  := l_grid || rpad(l_result.get_number('tool_calls_count') || case when regexp_like(l_answer, q.expected_fact, 'i') then '+' else '-' end, 4);
    end loop question_loop;

    sys.dbms_output.put_line(rpad(p_label, 26) || rpad(l_n_ret || '/9', 7) || rpad(l_n_fact || '/10', 7) || rpad(l_calls, 7)
      || rpad(round(l_chars / greatest(l_n_res, 1)), 8) || rpad(nvl(l_sent_all, '-'), 6) || rpad(l_in, 8)
      || rpad(round(extract(minute from (systimestamp - l_t)) * 60 + extract(second from (systimestamp - l_t))), 6) || l_grid);
  end run_list;
begin
  if lower(c_part) = 'search' then
    sys.dbms_output.put_line(null);
    sys.dbms_output.put_line('(part 3 skipped: no agent runs)');
    return;
  end if;

  sys.dbms_output.put_line(null);
  sys.dbms_output.put_line('=== 3. The question list through the agent (5 sources each; cells: tool calls, + when the answer has the fact) ===');
  sys.dbms_output.put_line(rpad('setting', 26) || rpad('retr', 7) || rpad('fact', 7) || rpad('calls', 7) || rpad('chars', 8)
    || rpad('sent', 6) || rpad('in', 8) || rpad('sec', 6) || 'Q1  Q2  Q3  Q4  Q5  Q6  Q7  Q8  Q9  Q10');
  run_list('1 surrounding (stored)', 1, false);
  run_list('0 surrounding',          0, false);
  run_list('query rewriting on',     1, true);
  sys.dbms_output.put_line('retr: questions whose expected document was in a tool result. chars: mean size of one tool result.');
  sys.dbms_output.put_line('sent: the max_sources values the model passed. in: input tokens of the 10 runs.');

  restore_stored(l_stored_map);
  sys.dbms_output.put_line('(stored configuration put back)');
exception
  when others then
    restore_stored(l_stored_map);
    raise;
end;
/
set feedback on
