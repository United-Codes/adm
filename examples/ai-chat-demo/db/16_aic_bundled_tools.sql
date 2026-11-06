-- The tools that ship with the AI Pack, on the same documents. Costs one bundled agent run per user
-- (about 20,000 input tokens each). It runs the agent through run_as, so any session works.
--
--   sql -name <connection> @16_aic_bundled_tools.sql
--
-- Part A  The bundled search tool ADM_SEARCH_FILES, called as a function: it reads the Oracle Text
--         index that step 4 made current, and applies the same access check as the RAG tools.
-- Part B  The bundled agent adm_doc_assistant, run as each user with aic_agent_api.run_as. It uses
--         the six bundled tools, no RAG. Different method (key words, not meaning), same documents.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off
set linesize 200
alter session set nls_numeric_characters = '.,';

prompt
prompt === Part A: ADM_SEARCH_FILES as a function, per user ===
declare
  procedure show (p_user in varchar2, p_terms in varchar2) is
    l_out  clob;
    l_docs varchar2(1000 char);
    l_n    number;
  begin
    adm_context_api.system_user_login(p_user);
    l_out := adm_ai_agent_tools_api.search_files('{"search_expressions":' || p_terms || '}');
    select count(*), listagg(d.name, ', ') within group (order by d.name)
      into l_n, l_docs
      from json_table(l_out, '$[*]' columns (name varchar2(200 char) path '$.document_name')) d;
    sys.dbms_output.put_line(rpad(p_user, 10) || p_terms || ' -> ' || l_n || ' file(s): ' || coalesce(l_docs, substr(l_out, 1, 150)));
  end show;
begin
  show('AIC_LEGAL', '["notice"]');
  show('AIC_HR',    '["notice"]');
  show('AIC_LEGAL', '["salary"]');
  show('AIC_HR',    '["salary"]');
  show('AIC_HR',    '["Helios"]');
end;
/

prompt
prompt === Part B: the bundled agent adm_doc_assistant, as each user ===
declare
  procedure ask (p_user in varchar2, p_question in varchar2) is
    l_result json_object_t;
    l_t      timestamp;
  begin
    l_t := systimestamp;
    l_result := aic_agent_api.run_as(p_user, 'adm_doc_assistant', p_question);
    sys.dbms_output.put_line('--- as ' || p_user);
    sys.dbms_output.put_line('Q: ' || p_question);
    sys.dbms_output.put_line('A: ' || substr(l_result.get_clob('final_message'), 1, 600));
    sys.dbms_output.put_line('   tool calls ' || l_result.get_number('tool_calls_count')
      || ', tokens ' || l_result.get_object('usage').get_number('prompt_tokens')
      || ' in / ' || l_result.get_object('usage').get_number('completion_tokens')
      || ' out, ' || round(extract(second from (systimestamp - l_t)) + 60 * extract(minute from (systimestamp - l_t)), 1) || ' s');
    sys.dbms_output.put_line(null);
  end ask;
begin
  ask('AIC_LEGAL', 'Which of my documents mention a notice period? Name the documents.');
  ask('AIC_HR',    'Which of my documents mention a notice period? Name the documents.');
end;
/
-- Leave no ADM user on the session, so a later call in it does not run as that user.
begin
  adm_context_api.clear_context;
end;
/
set feedback on
