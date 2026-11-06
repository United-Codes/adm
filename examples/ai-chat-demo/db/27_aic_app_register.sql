-- Lesson 7: the application side. Run as the APPLICATION schema (AIC_APP), not as the ADM schema,
-- after 24_aic_bridge_setup.sql. Re-runnable. Calls no model.
--
--   sql aic_app@<host>:<port>/<service> @27_aic_app_register.sql
--
-- The schema needs UC AI (the same release as the ADM schema) and must be in the APEX workspace that
-- holds the web credential OPENAI. 22_aic_app_schema.sql creates such a schema; the lesson installs
-- UC AI into it.
--
-- It creates, in this schema:
--   1. the synonym aic_rag_bridge_api for the bridge package in the ADM schema
--   2. the package aic_app_tools_api (26_aic_app_tools_api.pks/.pkb)
--   3. two tools, AIC_APP_SEARCH_CONTRACTS and AIC_APP_SEARCH_POLICIES, with the tag aic_app
--   4. the prompt profile AIC_APP_ASSISTANT and the agent aic_app_assistant
--
-- If the ADM schema has another name than ADM, change the define below.

set define '&'
set verify off
set serveroutput on
set feedback off

define adm_schema = 'ADM'

whenever sqlerror exit failure

prompt === 1. the synonym for the bridge ===
create or replace synonym aic_rag_bridge_api for &adm_schema..aic_rag_bridge_api;

prompt === 2. the package aic_app_tools_api ===
set define off
@@26_aic_app_tools_api.pks
@@26_aic_app_tools_api.pkb

prompt === 3. the two tools ===
declare
  procedure register_tool (
    p_code          in varchar2
  , p_description   in varchar2
  , p_function_call in varchar2
  )
  as
    l_tool_id uc_ai_tools.id%type;
  begin
    l_tool_id := uc_ai_tools_api.merge_tool_from_schema( -- @dblinter ignore(g-2135): merge_tool_from_schema is a function, and this script does not need the id
      p_tool_code        => p_code
    , p_description      => p_description
    , p_function_call    => p_function_call
    , p_json_schema      => json_object_t('{
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "What to look for. Key words, not a whole sentence." }
        },
        "required": ["query"]
      }')
    , p_tags             => apex_t_varchar2('aic_app')
    , p_code_mode_access => 'direct'
    );
  end register_tool;
begin
  register_tool(
    p_code          => 'AIC_APP_SEARCH_CONTRACTS'
  , p_description   => 'Search the contracts of the company (supply, maintenance, framework and distribution '
                    || 'agreements and their amendments). Returns the best matching passages with the '
                    || 'name of the document. Use short queries made of the key words, for example '
                    || '"Alpenwerk notice period termination".'
  , p_function_call => 'return aic_app_tools_api.search_contracts(:parameters);'
  );
  register_tool(
    p_code          => 'AIC_APP_SEARCH_POLICIES'
  , p_description   => 'Search the policies of the company (travel, remote work, handbook, salary bands). '
                    || 'Returns the best matching passages with the name of the document. Use short '
                    || 'queries made of the key words, for example "travel hotel limit per night".'
  , p_function_call => 'return aic_app_tools_api.search_policies(:parameters);'
  );
  commit;
end;
/

prompt === 4. the prompt profile and the agent ===
declare
  l_system_prompt clob;
  l_config        clob;
  l_exists        number;
  l_id            number;
begin
  l_system_prompt := q'[You are the document assistant of the purchasing application of Example Works GmbH. You answer questions from the documents of the company, and only from them.

Rules:
1. Search before you answer. Call the search tools with short queries made of the key words (names, terms), not with the whole question. If the first search finds nothing useful, try again with other words.
2. Answer only from the passages the tools return. Never answer from memory, and never fill a gap with a guess.
3. Citation rule: every fact in your answer comes with the quoted clause or sentence in quotation marks, followed by the name of the document it comes from in brackets.
4. If the documents give different answers (for example two versions of a policy, or a contract and its amendment), say so, name both documents, and say which one is newer when the documents tell you.
5. If a tool returns the status no_passages, say that you found nothing in the documents you can see. If it returns error, say that the search is not available right now. Do not try to answer in that case.
6. Keep the answer short.]';

  l_config := '{
    "g_enable_tools": true,
    "g_tool_tags": ["aic_app"],
    "g_max_tool_calls": 6,
    "g_apex_web_credential": "OPENAI"
  }';

  select count(*) into l_exists from uc_ai_prompt_profiles where code = 'AIC_APP_ASSISTANT' and version = 1;
  if l_exists = 0 then
    l_id := uc_ai_prompt_profiles_api.create_prompt_profile( -- @dblinter ignore(g-2135): create_prompt_profile is a function, and this script does not need the id
      p_code                   => 'AIC_APP_ASSISTANT'
    , p_description            => 'Demo: the purchasing assistant, searches ADM through the bridge'
    , p_system_prompt_template => l_system_prompt
    , p_user_prompt_template   => '{question}'
    , p_provider               => uc_ai.c_provider_openai
    , p_model                  => uc_ai_openai.c_model_gpt_6_1_sol
    , p_model_config_json      => l_config
    , p_parameters_schema      => '{
        "type": "object",
        "properties": { "question": { "type": "string", "description": "What the user asked" } },
        "required": ["question"]
      }'
    , p_version                => 1
    , p_status                 => uc_ai_prompt_profiles_api.c_status_active
    );
  else
    uc_ai_prompt_profiles_api.update_prompt_profile(
      p_code                   => 'AIC_APP_ASSISTANT'
    , p_version                => 1
    , p_description            => 'Demo: the purchasing assistant, searches ADM through the bridge'
    , p_system_prompt_template => l_system_prompt
    , p_user_prompt_template   => '{question}'
    , p_provider               => uc_ai.c_provider_openai
    , p_model                  => uc_ai_openai.c_model_gpt_6_1_sol
    , p_model_config_json      => l_config
    );
  end if;

  select count(*) into l_exists from uc_ai_agents where code = 'aic_app_assistant' and version = 1;
  if l_exists = 0 then
    l_id := uc_ai_agents_api.create_agent( -- @dblinter ignore(g-2135): create_agent is a function, and this script does not need the id
      p_code                 => 'aic_app_assistant'
    , p_description          => 'Demo agent of the purchasing application: answers from the ADM collections through the bridge'
    , p_agent_type           => uc_ai_agents_api.c_type_profile
    , p_prompt_profile_code  => 'AIC_APP_ASSISTANT'
    , p_max_history_messages => 20
    , p_status               => uc_ai_agents_api.c_status_active
    );
  end if;
  commit;
end;
/

whenever sqlerror continue

prompt
prompt Registered in this schema:
col kind   format a8
col code   format a26
col detail format a70
select 'synonym' as kind, synonym_name as code, table_owner || '.' || table_name as detail from user_synonyms where synonym_name = 'AIC_RAG_BRIDGE_API'
union all
select 'package', object_name, object_type || ' ' || status from user_objects where object_name = 'AIC_APP_TOOLS_API'
union all
select 'tool', t.code, 'tags: ' || (select listagg(g.tag_name, ', ') within group (order by g.tag_name) from uc_ai_tool_tags g where g.tool_id = t.id)
  from uc_ai_tools t where t.code like 'AIC\_APP\_%' escape '\'
union all
select 'profile', p.code, p.status || ', ' || p.provider || '/' || p.model from uc_ai_prompt_profiles p where p.code = 'AIC_APP_ASSISTANT'
union all
select 'agent', a.code, a.status || ', profile ' || a.prompt_profile_code from uc_ai_agents a where a.code = 'aic_app_assistant';
set feedback on
