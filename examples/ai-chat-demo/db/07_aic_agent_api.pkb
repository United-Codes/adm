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
  begin
    select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
    apex_util.set_workspace(l_workspace);

    -- Any application will do: the session only has to exist. It is deleted again below.
    select min(application_id) into l_app_id from apex_applications where workspace = l_workspace;

    -- 1. the APEX session, so that execute_agent does not create (and run init code for) its own
    apex_session.create_session(p_app_id => l_app_id, p_page_id => 1, p_username => p_username);

    -- 2. the ADM context, AFTER the init code of the session has run
    adm_context_api.system_user_login(p_username => p_username);

    -- 3. the agent
    select count(*)
      into l_is_followup
      from uc_ai_agent_executions
     where session_id = p_session_id;

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
      apex_debug.error(c_scope_prefix || 'run_as: %s', sqlerrm);
      begin
        apex_session.delete_session;
      exception
        when others then
          null;
      end;
      raise;
  end run_as;

end aic_agent_api;
/
