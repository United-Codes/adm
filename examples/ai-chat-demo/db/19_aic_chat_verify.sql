-- Lesson 4: prove who the agent ran as when it ran from the chat page. Run in SQLcl or SQL*Plus,
-- connected as the ADM schema owner, after you asked questions in the page as AIC_LEGAL and AIC_HR.
-- It reads data only and makes no model call.
--
--   @19_aic_chat_verify.sql
--
-- created_by and apex_user are the account that ran the agent. searched_as is the ADM user that the
-- search tool read from the ADM context while the model was running. All three must be the
-- signed-in user. The chat app is application 218, so runs from other applications are left out.

set linesize 200
set pagesize 100
set feedback off
column execution_id format 999
column created_by   format a10
column apex_user    format a10
column question     format a60
column tool_name    format a21
column result_status format a24
column searched_as  format a22

-- ---------------------------------------------------------------------------
-- The runs of the chat page
-- ---------------------------------------------------------------------------
select e.id as execution_id
     , e.created_by
     , e.apex_user
     , (select substr(m.content, 1, 60)
          from uc_ai_agent_messages m
         where m.execution_id = e.id
           and m.role = 'user'
           and m.seq = (select min(f.seq) from uc_ai_agent_messages f where f.execution_id = e.id and f.role = 'user')) as question
  from uc_ai_agent_executions e
 where e.agent_id = (select a.id from uc_ai_agents a where a.code = 'aic_assistant')
   and e.apex_app_id = 218
 order by e.id;

-- ---------------------------------------------------------------------------
-- Who each search ran as
-- ---------------------------------------------------------------------------
select m.execution_id
     , m.tool_name
     , regexp_substr(m.tool_output, '"status":"[a-z_]+"')      as result_status
     , regexp_substr(m.tool_output, '"searched_as":"[A-Z_]+"') as searched_as
  from uc_ai_agent_messages m
 where m.role = 'tool_result'
   and m.execution_id in (select e.id
                            from uc_ai_agent_executions e
                           where e.agent_id = (select a.id from uc_ai_agents a where a.code = 'aic_assistant')
                             and e.apex_app_id = 218)
 order by m.execution_id, m.seq;
set feedback on
