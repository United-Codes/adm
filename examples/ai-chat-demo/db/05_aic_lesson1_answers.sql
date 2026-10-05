-- Lesson 1: a first answer from one collection, and the follow-up it cannot answer.
-- Run as the ADM schema owner, after step 4. Costs two answer calls and three search embeddings.
--
--   sql -name <connection> @05_aic_lesson1_answers.sql
--
-- adm_ai_rag_api.generate_answer searches ONE collection, passes the best passages to the answer
-- model, and returns the answer with its sources. It runs as the current ADM user: every passage
-- goes through the access check of that user first.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set long 4000
set feedback off
set linesize 200
alter session set nls_numeric_characters = '.,';

declare
  l_contracts adm_ai_rag_collections.rag_collection_id%type;
  l_policies  adm_ai_rag_collections.rag_collection_id%type;

  procedure ask (
    p_collection_id in number
  , p_label         in varchar2
  , p_question      in varchar2
  )
  as
    l_answer clob;
    l_t      timestamp;
  begin
    l_t := systimestamp;
    l_answer := adm_ai_rag_api.generate_answer(
      p_rag_collection_id => p_collection_id
    , p_query             => p_question
    );
    sys.dbms_output.put_line('--- ' || p_label);
    sys.dbms_output.put_line('Q: ' || p_question);
    sys.dbms_output.put_line('A: ' || l_answer);
    sys.dbms_output.put_line('   (' || round(extract(second from (systimestamp - l_t)), 1) || ' s)');
    sys.dbms_output.put_line(null);
  end ask;
begin
  adm_context_api.system_user_login('AIC_LEGAL');
  select rag_collection_id into l_contracts from adm_ai_rag_collections where collection_name = 'aic_contracts';
  select rag_collection_id into l_policies  from adm_ai_rag_collections where collection_name = 'aic_policies';

  ask(l_contracts, '1. a question the contracts can answer',
      'What notice period applies if we want to end the Alpenwerk maintenance contract?');

  -- what the answer was built from
  sys.dbms_output.put_line('Sources of that answer (prepare_sources):');
  <<source_loop>>
  for r in (
    select document_name, round(avg_score, 3) as score, chunk_count
      from table(adm_ai_rag_api.prepare_sources(
             p_rag_collection_id => l_contracts
           , p_query             => 'What notice period applies if we want to end the Alpenwerk maintenance contract?'))
  ) loop
    sys.dbms_output.put_line('  ' || rpad(r.document_name, 38) || ' score ' || r.score || ', chunks ' || r.chunk_count);
  end loop source_loop;
  sys.dbms_output.put_line(null);

  ask(l_contracts, '2. the natural follow-up: the same collection',
      'And what does our travel policy say about hotel costs?');

  ask(l_policies, '3. the same follow-up, if YOU pick the right collection',
      'And what does our travel policy say about hotel costs?');
end;
/
set feedback on
