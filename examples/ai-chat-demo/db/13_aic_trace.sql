-- Reads the trace of the most recent conversation of the agent aic_assistant. Costs nothing.
--
--   sql -name <connection> @13_aic_trace.sql
--
-- Two tables hold the trace:
--   uc_ai_agent_executions  one row per run: status, tool calls, tokens, who ran it
--   uc_ai_agent_messages    one row per message: the user, each tool call, each tool result, the answer
-- A conversation is every execution with the same session_id.
--
-- Read tool_output, not tool_status. tool_status says "success" when the tool function returned,
-- and ours always returns. A search that found nothing, a missing identity and a failure all come
-- back as success. The truth is in the "status" inside tool_output.

set define off
set serveroutput on
set feedback off
set linesize 220
set long 20000
alter session set nls_numeric_characters = '.,';

column execution_id format 999
column status       format a10
column created_by   format a10
column audience     format a14
column seconds      format 99.9
column tool_name    format a22
column seq          format 999
column role         format a12
column what         format a110
column document     format a36
column text         format a70
column tool_status  format a12
column result_status format a14
column n            format 999

prompt
prompt === 1. The runs of the latest conversation: tokens, tool calls, who ran them ===
select e.id as execution_id
     , e.status
     , e.tool_calls_count
     , e.total_input_tokens  as tokens_in
     , e.total_output_tokens as tokens_out
     , round(extract(second from (e.completed_at - e.started_at))
             + 60 * extract(minute from (e.completed_at - e.started_at)), 1) as seconds
     , e.created_by
     , e.audience
  from uc_ai_agent_executions e
 where e.session_id = (select max(session_id) keep (dense_rank last order by started_at)
                         from uc_ai_agent_executions
                        where agent_id = (select id from uc_ai_agents where code = 'aic_assistant'))
 order by e.id;

prompt
prompt === 2. The messages of the last run, in order ===
select m.seq
     , m.role
     , m.tool_name
     , case m.role
         when 'tool_call'   then to_char(substr(m.tool_input, 1, 110))
         when 'tool_result' then 'status ' || json_value(m.tool_output, '$.status') || ', ' || length(m.tool_output) || ' characters'
         else to_char(replace(substr(m.content, 1, 110), chr(10), ' '))
       end as what
  from uc_ai_agent_messages m
 where m.execution_id = (select max(id) from uc_ai_agent_executions
                          where agent_id = (select id from uc_ai_agents where code = 'aic_assistant'))
 order by m.seq;

prompt
prompt === 3. What a tool result held: the passages the model saw (the latest run that found some) ===
select p.document
     , p.score
     , p.matched_chunks
     , replace(substr(p.text, 1, 70), chr(10), ' ') as text
  from uc_ai_agent_messages m
  cross apply json_table(m.tool_output, '$.passages[*]'
         columns (document       varchar2(200) path '$.document'
                , score          number        path '$.score'
                , matched_chunks number        path '$.matched_chunks'
                , text           clob          path '$.text')) p
 where m.role = 'tool_result'
   and m.id = (select max(x.id)
                 from uc_ai_agent_messages x
                where x.role = 'tool_result'
                  and json_value(x.tool_output, '$.status') = 'ok'
                  and x.execution_id in (select e.id from uc_ai_agent_executions e
                                          where e.agent_id = (select id from uc_ai_agents where code = 'aic_assistant')))
 order by p.score desc;

prompt
prompt === 4. tool_status against the real status in tool_output, over every run of the agent ===
select m.tool_status
     , json_value(m.tool_output, '$.status') as result_status
     , count(*) as n
  from uc_ai_agent_messages m
 where m.role = 'tool_result'
   and m.execution_id in (select e.id from uc_ai_agent_executions e
                           where e.agent_id = (select id from uc_ai_agents where code = 'aic_assistant'))
 group by m.tool_status, json_value(m.tool_output, '$.status')
 order by 3 desc;
set feedback on
