create or replace package body aic_agent_api as
  pragma serially_reusable;

  c_scope_prefix constant varchar2(30 char) := 'aic_agent_api.';

  function run_as (
    p_username   in varchar2
  , p_agent_code in varchar2
  , p_question   in clob
  , p_session_id in varchar2 default null
  ) return json_object_t
  as
    l_workspace   apex_workspaces.workspace%type;
    l_app_id      apex_applications.application_id%type;
    l_result      json_object_t;
    l_is_followup number;
    l_input       json_object_t := json_object_t();
    -- the ADM context of the caller, put back when the run fails
    l_prev_user   varchar2(255 char);
    l_prev_role   varchar2(30 char);
    l_prev_source varchar2(30 char);
  begin
    l_prev_user   := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username);
    l_prev_role   := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_role);
    l_prev_source := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_access_source);

    select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
    apex_util.set_workspace(l_workspace);

    -- Any application of THIS schema will do: the session only has to exist. It is deleted again
    -- below. UC AI runs the tool code in the parsing schema of this application, so an application
    -- of another schema in the same workspace (lesson 7) must not be picked.
    select min(application_id) into l_app_id from apex_applications where workspace = l_workspace and owner = user;

    -- 1. the APEX session, so that execute_agent does not create (and run init code for) its own
    apex_session.create_session(p_app_id => l_app_id, p_page_id => 1, p_username => p_username);

    -- 2. the ADM context, AFTER the init code of the session has run
    adm_context_api.system_user_login(p_username => p_username);

    -- 3. the agent
    select case when exists (select 1 from uc_ai_agent_executions x where x.session_id = p_session_id) then 1 else 0 end
      into l_is_followup
      from dual;

    if l_is_followup > 0 then
      l_result := uc_ai_agents_api.execute_agent(
        p_agent_code        => p_agent_code
      , p_follow_up_message => p_question
      , p_session_id        => p_session_id
      );
    else
      l_input.put('question', p_question);
      l_result := uc_ai_agents_api.execute_agent(
        p_agent_code       => p_agent_code
      , p_input_parameters => l_input
      , p_session_id       => nvl(p_session_id, uc_ai_agents_api.generate_session_id)
      );
    end if;

    apex_session.delete_session;
    return l_result;
  exception
    when others then
      -- Log first: a handled error in the cleanup below would clear this one (ORA-21002 on raise).
      adm_error.log_error(
        p_scope => c_scope_prefix || 'run_as'
      , p_extra => 'user: ' || p_username || ', agent: ' || p_agent_code
      );
      if apex_application.g_instance is not null then
        apex_session.delete_session;
      end if;
      -- The caller gets its own ADM context back, not the user of the failed run. After the
      -- delete: the cleanup code of the ADM application clears the context when its session ends.
      adm_context_api.restore_context(
        p_username      => l_prev_user
      , p_role          => l_prev_role
      , p_access_source => l_prev_source
      );
      raise;
  end run_as;

end aic_agent_api;
/
