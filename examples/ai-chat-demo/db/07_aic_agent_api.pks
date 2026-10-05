create or replace package aic_agent_api as
  pragma serially_reusable;

  /**
   * A demo helper that runs a UC AI agent as an ADM user from plain SQL.
   *
   * THIS IS AN EXCEPTION, NOT THE WAY ADM AGENTS NORMALLY RUN. In a product, an agent runs
   *   - inside an existing APEX session of a signed-in user, whose application initialization
   *     code has already put the user into the ADM context, or
   *   - from the chat plug-in (ucAiChat), which runs the agent in a job. The Session Init Code
   *     of the plug-in attaches the APEX session (apex_session.attach) and calls
   *     adm_context_api.establish_from_session.
   * Both paths have a real login. This helper has none: it takes a user name and trusts it.
   * Never expose it to end users and never pass it a name that came from outside.
   *
   * Why it exists. uc_ai_agents_api.execute_agent creates a synthetic APEX session when the
   * database session has none, on the first application of the first workspace. APEX runs that
   * application's initialization code for the new session, and in ADM that code ends in
   * clear_context, because the synthetic user has no ADM role. So the FIRST execute_agent call
   * of a database session wipes the ADM context that you set before it, every tool then sees no
   * user, and a tool that is built on the access check returns nothing. The agent explains that
   * as "nothing found", which looks like a permission result.
   *
   * The order that works: create the APEX session yourself first (so execute_agent finds one and
   * creates none), THEN establish the ADM context, THEN run the agent.
   */

  /**
   * Runs an agent as an ADM user and returns the result of uc_ai_agents_api.execute_agent.
   * Pass the session id of an earlier run to ask a follow-up in the same conversation.
   *
   * @param p_username   ADM user name; must exist in adm_users. Not checked against any login.
   * @param p_agent_code Code of the UC AI agent
   * @param p_question   The question, or the follow-up question
   * @param p_session_id Session id for a follow-up; null starts a new conversation
   * @return The execute_agent result: final_message, usage, session_id, execution_id ...
   */
  function run_as (
    p_username   in varchar2
  , p_agent_code in varchar2
  , p_question   in clob
  , p_session_id in varchar2 default null
  ) return json_object_t;

end aic_agent_api;
/
