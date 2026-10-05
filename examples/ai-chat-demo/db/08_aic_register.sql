-- Step 7 of 7: one tool, one prompt profile, one agent. Run as the ADM schema owner, after the
-- packages of steps 5 and 6. Re-runnable: it resets the agent to its FIRST state, with one tool.
-- 11_aic_second_tool.sql then adds the second one.
--
--   tool     AIC_SEARCH_CONTRACTS  calls aic_rag_tools_api.search_contracts, tagged aic_demo
--   profile  AIC_ASSISTANT         system prompt, model, and which tools it gets (by tag)
--   agent    aic_assistant         what you run with execute_agent
--
-- The profile carries its OWN provider, model and web credential. The ADM settings
-- AI_AGENT_PROVIDER, AI_AGENT_MODEL and the like only reach the two profiles that the AI Pack
-- ships (ADM_DOC_ASSISTANT and ADM_DOC_AGENT). A profile of your own is yours to configure.
--
-- The profile selects its tools by TAG ("g_tool_tags"), not by name. A tool that carries the tag
-- is available to the agent without a change to the profile. 11_aic_second_tool.sql uses that.

set define off
set serveroutput on
set feedback off

-- ---------------------------------------------------------------------------
-- The tool
-- ---------------------------------------------------------------------------
declare
  l_tool_id uc_ai_tools.id%type;
begin
  -- Back to the first state: the second tool does not exist yet.
  delete from uc_ai_tools where code = 'AIC_SEARCH_POLICIES';

  l_tool_id := uc_ai_tools_api.merge_tool_from_schema(
    p_tool_code     => 'AIC_SEARCH_CONTRACTS'
  , p_description   => 'Search the contracts of the company (supply, maintenance, framework and distribution '
                    || 'agreements and their amendments). Returns the best matching passages with the '
                    || 'name of the document. Use it for questions about parties, terms, notice periods, '
                    || 'prices, liability and termination. Use short queries made of the key words, for '
                    || 'example "Alpenwerk notice period termination".'
  , p_function_call => 'return aic_rag_tools_api.search_contracts(:parameters);'
  , p_json_schema   => json_object_t('{
      "type": "object",
      "properties": {
        "query":       { "type": "string", "description": "What to look for. Key words, not a whole sentence." },
        "max_sources": { "type": "number", "description": "How many documents at most. Default 5." }
      },
      "required": ["query"]
    }')
  , p_tags          => apex_t_varchar2('aic_demo')
  , p_code_mode_access => 'direct'
  );
  commit;
end;
/

-- ---------------------------------------------------------------------------
-- The prompt profile
-- ---------------------------------------------------------------------------
declare
  l_system_prompt clob;
  l_config        clob;
  l_exists        number;
  l_profile_id    number;
begin
  l_system_prompt := q'[You are the document assistant of Example Works GmbH. You answer questions from the documents of the company, and only from them.

Rules:
1. Search before you answer. Call the search tools with short queries made of the key words (names, terms), not with the whole question. If the first search finds nothing useful, try again with other words.
2. Answer only from the passages the tools return. Never answer from memory, and never fill a gap with a guess.
3. Citation rule: every fact in your answer comes with the quoted clause or sentence in quotation marks, followed by the name of the document it comes from in brackets, for example: "Either party may terminate ... 30 days ..." (contract_x.pdf).
4. If the documents give different answers (for example two versions of a policy, or a contract and its amendment), say so, name both documents, and say which one is newer when the documents tell you.
5. If a tool returns the status no_passages, say that you found nothing in the documents you can see. If it returns no_identity or error, say that the search is not available right now. Do not try to answer in that case.
6. Keep the answer short.]';

  l_config := '{
    "g_enable_tools": true,
    "g_tool_tags": ["aic_demo"],
    "g_max_tool_calls": 6,
    "g_apex_web_credential": "OPENAI"
  }';

  select count(*) into l_exists from uc_ai_prompt_profiles where code = 'AIC_ASSISTANT' and version = 1;

  if l_exists = 0 then
    -- create_prompt_profile makes a draft unless you pass the status
    l_profile_id := uc_ai_prompt_profiles_api.create_prompt_profile(
      p_code                   => 'AIC_ASSISTANT'
    , p_description            => 'Demo: answers from the contracts and policies of Example Works GmbH'
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
      p_code                   => 'AIC_ASSISTANT'
    , p_version                => 1
    , p_description            => 'Demo: answers from the contracts and policies of Example Works GmbH'
    , p_system_prompt_template => l_system_prompt
    , p_user_prompt_template   => '{question}'
    , p_provider               => uc_ai.c_provider_openai
    , p_model                  => uc_ai_openai.c_model_gpt_6_1_sol
    , p_model_config_json      => l_config
    );
  end if;
  commit;
end;
/

-- ---------------------------------------------------------------------------
-- The agent
-- ---------------------------------------------------------------------------
declare
  l_agent_id number;
begin
  begin
    select id into l_agent_id from uc_ai_agents where code = 'aic_assistant' and version = 1;
    uc_ai_agents_api.update_agent(
      p_id                   => l_agent_id
    , p_description          => 'Demo agent: answers from the contracts (and policies) of Example Works GmbH'
    , p_prompt_profile_code  => 'AIC_ASSISTANT'
    , p_max_history_messages => 20
    );
  exception
    when no_data_found then
      l_agent_id := uc_ai_agents_api.create_agent(
        p_code                 => 'aic_assistant'
      , p_description          => 'Demo agent: answers from the contracts (and policies) of Example Works GmbH'
      , p_agent_type           => uc_ai_agents_api.c_type_profile
      , p_prompt_profile_code  => 'AIC_ASSISTANT'
      , p_max_history_messages => 20
      , p_status               => uc_ai_agents_api.c_status_active
      );
  end;
  commit;
end;
/

prompt
prompt Registered:
col kind   format a10
col code   format a24
col detail format a60
select 'tool' as kind, t.code, 'tags: ' || (select listagg(tag_name, ', ') within group (order by tag_name) from uc_ai_tool_tags g where g.tool_id = t.id) as detail
  from uc_ai_tools t where t.code like 'AIC\_%' escape '\'
union all
select 'profile', p.code, p.status || ', ' || p.provider || '/' || p.model from uc_ai_prompt_profiles p where p.code = 'AIC_ASSISTANT'
union all
select 'agent', a.code, a.status || ', profile ' || a.prompt_profile_code from uc_ai_agents a where a.code = 'aic_assistant';
set feedback on
