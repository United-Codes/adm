-- The tools that ship with the AI Pack, on the same documents. Costs one bundled agent run per user
-- (about 3,000 to 8,000 tokens). Run it in a FRESH SQLcl session.
--
--   sql -name <connection> @16_aic_bundled_tools.sql
--
-- Part A  The bundled search tool ADM_SEARCH_FILES, called as a function: it reads the Oracle Text
--         index that step 4 made current, and applies the same access check as the RAG tools.
-- Part B  The bundled agent adm_doc_assistant, run as each user with aic_agent_api.run_as. It uses
--         the six bundled tools, no RAG. Different method (key words, not meaning), same documents.

set define off
set serveroutput on
set feedback off
set linesize 200
alter session set nls_numeric_characters = '.,';

prompt
prompt === Part A: ADM_SEARCH_FILES as a function, per user ===
declare
  l_out clob;
  procedure show (p_user in varchar2, p_terms in varchar2) is
    l_docs varchar2(1000 char);
    l_n    number;
  begin
    adm_context_api.system_user_login(p_user);
    l_out := adm_ai_agent_tools_api.search_files('{"search_expressions":' || p_terms || '}');
    select count(*), listagg(d.name, ', ') within group (order by d.name)
      into l_n, l_docs
      from json_table(l_out, '$[*]' columns (name varchar2(200) path '$.document_name')) d;
    dbms_output.put_line(rpad(p_user, 10) || p_terms || ' -> ' || l_n || ' file(s): ' || nvl(l_docs, substr(l_out, 1, 150)));
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
  l_result json_object_t;
  l_t      timestamp;
  procedure ask (p_user in varchar2, p_question in varchar2) is
  begin
    l_t := systimestamp;
    l_result := aic_agent_api.run_as(p_user, 'adm_doc_assistant', p_question);
    dbms_output.put_line('--- as ' || p_user);
    dbms_output.put_line('Q: ' || p_question);
    dbms_output.put_line('A: ' || substr(l_result.get_clob('final_message'), 1, 600));
    dbms_output.put_line('   tool calls ' || l_result.get_number('tool_calls_count')
      || ', tokens ' || l_result.get_object('usage').get_number('prompt_tokens')
      || ' in / ' || l_result.get_object('usage').get_number('completion_tokens')
      || ' out, ' || round(extract(second from (systimestamp - l_t)) + 60 * extract(minute from (systimestamp - l_t)), 1) || ' s');
    dbms_output.put_line('');
  end ask;
begin
  ask('AIC_LEGAL', 'Which of my documents mention a notice period? Name the documents.');
  ask('AIC_HR',    'Which of my documents mention a notice period? Name the documents.');
end;
/
set feedback on
