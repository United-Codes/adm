-- The question list, and the retrieval sweep. Run as the ADM schema owner, after step 7.
-- Costs 10 questions x 5 settings = 50 search embeddings (a few hundred tokens in all). No answer
-- model is called: this measures RETRIEVAL only, which is where most wrong answers start.
--
--   sql -name <connection> @14_aic_questions.sql
--
-- aic_questions holds 10 questions with the document that must be found for each. Question 9 is
-- asked as the HR user and question 8 as the Legal user, because each document is restricted to
-- one of them; every other question is asked as AIC_LEGAL. Question 10 has NO answer in the
-- documents: its correct result is that nothing is retrieved, and that the answer says so.
-- expected_fact is a regular expression that the final answer must match (15_aic_agent_questions.sql).
--
-- The sweep calls the tool function with the question text as the search text, the way
-- generate_answer does, and varies one knob at a time:
--   score threshold 0.5 (the collection default), 0.4, 0.3
--   hybrid search on (keyword search mixed in), with the threshold at 0.5 and at 0.4
-- A cell shows the rank of the expected document among the documents returned and its score, or MISS.
-- The collection configuration is put back at the end.

set define off
set serveroutput on
set feedback off
set linesize 200
alter session set nls_numeric_characters = '.,';

create table if not exists aic_questions (
  q_no            number(2) primary key
, question        varchar2(300 char) not null
, collection_name varchar2(30 char)  not null
, expected_doc    varchar2(100 char)
, expected_fact   varchar2(100 char)
, ask_as          varchar2(30 char)  not null
);

delete from aic_questions;
insert into aic_questions values (1, 'What notice period applies to the Alpenwerk maintenance contract?',         'aic_contracts', 'contract_alpenwerk_maintenance.pdf', '30 days',                       'AIC_LEGAL');
insert into aic_questions values (2, 'How long is the notice period in the Ferrotek framework agreement?',        'aic_contracts', 'contract_ferrotek_framework.pdf',    'six months|6 months',           'AIC_LEGAL');
insert into aic_questions values (3, 'Was the notice period of the Nordlicht supply agreement changed?',          'aic_contracts', 'scan_nordlicht_amendment.pdf',       '120',                           'AIC_LEGAL');
insert into aic_questions values (4, 'How many days per week may I work remotely?',                               'aic_policies',  'remote_work_policy.pdf',             'three|3 days',                  'AIC_LEGAL');
insert into aic_questions values (5, 'What is the hotel limit per night for a business trip in a large city?',   'aic_policies',  'travel_policy_2026.pdf',             '165',                           'AIC_LEGAL');
insert into aic_questions values (6, 'What was the hotel limit in 2025?',                                         'aic_policies',  'travel_policy_2025.pdf',             '140',                           'AIC_LEGAL');
insert into aic_questions values (7, 'What is the notice period for an employee who resigns after probation?',   'aic_policies',  'employee_handbook.pdf',              'four weeks|4 weeks',            'AIC_LEGAL');
insert into aic_questions values (8, 'What is the liability cap in the Helios distribution agreement?',          'aic_contracts', 'contract_helios_distribution.pdf',   '2,000,000',                     'AIC_LEGAL');
insert into aic_questions values (9, 'Which salary band is a senior engineer in?',                                'aic_policies',  'salary_bands.pdf',                   'B4',                            'AIC_HR');
insert into aic_questions values (10, 'Does the company allow dogs in the office?',                               'aic_policies',  null,                                 'nothing|no information|not find|couldn|can.t|cannot|not mention', 'AIC_LEGAL');
commit;

declare
  type t_cell is table of varchar2(30 char) index by pls_integer;
  l_cells        t_cell;
  l_original     clob;
  l_collection   adm_ai_rag_collections.rag_collection_id%type;
  c_hybrid       constant varchar2(100 char) := '{"enabled": true}';

  -- rank and score of the expected document, MISS, or for "no answer" questions: ok / n false hits
  function cell (
    p_q         in aic_questions%rowtype
  , p_threshold in number
  ) return varchar2
  as
    l_out    clob;
    l_rank   pls_integer;
    l_score  number;
    l_count  pls_integer;
  begin
    adm_context_api.system_user_login(p_q.ask_as);
    l_out := aic_rag_tools_api.search(p_q.collection_name, p_q.question, p_score_threshold => p_threshold);
    select count(*) into l_count
      from json_table(l_out, '$.passages[*]' columns (document varchar2(200) path '$.document'));

    if p_q.expected_doc is null then
      return case when l_count = 0 then 'ok, none' else 'FALSE ' || l_count end;
    end if;

    select min(rn), min(score)
      into l_rank, l_score
      from (select d.document, d.score, row_number() over (order by d.score desc) rn
              from json_table(l_out, '$.passages[*]' columns (document varchar2(200) path '$.document', score number path '$.score')) d)
     where document = p_q.expected_doc;
    return case when l_rank is null then 'MISS' else '#' || l_rank || ' ' || to_char(l_score, 'FM0.000') end;
  end cell;

  procedure sweep (
    p_title in varchar2
  , p_thr1  in number
  , p_thr2  in number
  )
  as
  begin
    dbms_output.put_line('');
    dbms_output.put_line(p_title);
    dbms_output.put_line(rpad('Q', 4) || rpad('expected document', 38) || rpad('thr ' || p_thr1, 14) || 'thr ' || p_thr2);
    for q in (select * from aic_questions order by q_no) loop
      dbms_output.put_line(rpad(q.q_no, 4) || rpad(nvl(q.expected_doc, '(no answer exists)'), 38)
        || rpad(cell(q, p_thr1), 14) || cell(q, p_thr2));
    end loop;
  end sweep;
begin
  adm_context_api.system_login;
  select rag_collection_id into l_collection from adm_ai_rag_collections where collection_name = 'aic_contracts';

  sweep('Vector search only',  0.5, 0.4);
  sweep('Vector search only, lower still',  0.3, 0.2);
end;
/

-- Hybrid search: the same questions with the keyword search mixed in. The score is then a fused
-- RRF score (about 0.01 to 0.03), not a cosine similarity, and the threshold only gates the vector side.
declare
  l_config  json_object_t;
  l_originals json_object_t := json_object_t();
  l_cfg_clob clob;

  procedure set_hybrid (p_on in boolean) is
  begin
    adm_context_api.system_login;
    for c in (select rag_collection_id, collection_name, config_json from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
      if p_on then
        l_originals.put(c.collection_name, c.config_json);
        l_config := json_object_t.parse(c.config_json);
        l_config.put('hybrid_search', json_object_t('{"enabled": true}'));
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => l_config.to_clob);
      else
        l_cfg_clob := l_originals.get_clob(c.collection_name);
        adm_ai_rag_api.update_rag_collection(p_rag_collection_id => c.rag_collection_id, p_config_json => l_cfg_clob);
      end if;
    end loop;
    commit;
  end set_hybrid;

  function cell (
    p_q         in aic_questions%rowtype
  , p_threshold in number
  ) return varchar2
  as
    l_out    clob;
    l_rank   pls_integer;
    l_score  number;
    l_count  pls_integer;
  begin
    adm_context_api.system_user_login(p_q.ask_as);
    l_out := aic_rag_tools_api.search(p_q.collection_name, p_q.question, p_score_threshold => p_threshold);
    select count(*) into l_count
      from json_table(l_out, '$.passages[*]' columns (document varchar2(200) path '$.document'));
    if p_q.expected_doc is null then
      return case when l_count = 0 then 'ok, none' else 'FALSE ' || l_count end;
    end if;
    select min(rn), min(score)
      into l_rank, l_score
      from (select d.document, d.score, row_number() over (order by d.score desc) rn
              from json_table(l_out, '$.passages[*]' columns (document varchar2(200) path '$.document', score number path '$.score')) d)
     where document = p_q.expected_doc;
    return case when l_rank is null then 'MISS' else '#' || l_rank || ' ' || to_char(l_score, 'FM0.0000') end;
  end cell;
begin
  set_hybrid(true);
  dbms_output.put_line('');
  dbms_output.put_line('Hybrid search on (scores are RRF scores)');
  dbms_output.put_line(rpad('Q', 4) || rpad('expected document', 38) || rpad('thr 0.5', 14) || 'thr 0.4');
  for q in (select * from aic_questions order by q_no) loop
    dbms_output.put_line(rpad(q.q_no, 4) || rpad(nvl(q.expected_doc, '(no answer exists)'), 38)
      || rpad(cell(q, 0.5), 14) || cell(q, 0.4));
  end loop;
  set_hybrid(false);
  dbms_output.put_line('');
  dbms_output.put_line('(collection configuration restored: hybrid search off)');
exception
  when others then
    set_hybrid(false);
    raise;
end;
/
set feedback on
