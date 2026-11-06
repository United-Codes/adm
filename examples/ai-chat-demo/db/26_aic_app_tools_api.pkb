create or replace package body aic_app_tools_api as
  pragma serially_reusable;

  c_scope_prefix constant varchar2(30 char) := 'aic_app_tools_api.';

  function status_json (
    p_status     in varchar2
  , p_collection in varchar2
  , p_message    in varchar2
  , p_user       in varchar2 default aic_rag_bridge_api.c_service_user
  ) return clob
  as
    l_json json_object_t := json_object_t();
  begin
    l_json.put('status', p_status);
    l_json.put('collection', p_collection);
    if p_user is not null then
      l_json.put('searched_as', p_user);
    end if;
    l_json.put('message', p_message);
    return l_json.to_clob();
  end status_json;

  -- p_username null: the bridge searches as its fixed user. Otherwise as that ADM user.
  function search_passages_json (
    p_collection_name in varchar2
  , p_query           in varchar2
  , p_username        in varchar2
  ) return clob
  as
    l_passages clob;
    l_json     json_object_t;
    l_user     varchar2(255 char);
  begin
    l_user := nvl(p_username, aic_rag_bridge_api.c_service_user);
    if p_query is null or trim(p_query) is null then
      return status_json('error', p_collection_name, 'The parameter "query" is required. Call the tool again with a query.', l_user);
    end if;

    if p_username is null then
      select json_arrayagg(
               json_object(
                 'document'       value document_name
               , 'score'          value round(score, 3)
               , 'matched_chunks' value matched_chunks
               , 'text'           value passage_text
                 returning clob
               )
               order by score desc
               returning clob
             )
        into l_passages
        from table(
               aic_rag_bridge_api.search_passages(
                 p_collection_name => p_collection_name
               , p_query           => p_query
               )
             );
    else
      select json_arrayagg(
               json_object(
                 'document'       value document_name
               , 'score'          value round(score, 3)
               , 'matched_chunks' value matched_chunks
               , 'text'           value passage_text
                 returning clob
               )
               order by score desc
               returning clob
             )
        into l_passages
        from table(
               aic_rag_bridge_api.search_passages_for_user(
                 p_username        => p_username
               , p_collection_name => p_collection_name
               , p_query           => p_query
               )
             );
    end if;

    if l_passages is null then
      return status_json('no_passages', p_collection_name
        , 'No passage in the collection ' || p_collection_name || ' matches this query. Say so; do not answer from memory. You may try other words.'
        , l_user);
    end if;

    l_json := json_object_t();
    l_json.put('status', 'ok');
    l_json.put('collection', p_collection_name);
    l_json.put('searched_as', l_user);
    l_json.put('passages', json_array_t.parse(l_passages));
    return l_json.to_clob();
  exception
    when aic_rag_bridge_api.e_collection_not_found
      or aic_rag_bridge_api.e_collection_refused
      or aic_rag_bridge_api.e_user_refused
    then
      -- The bridge wrote these messages for a reader: the first line, without "ORA-nnnnn: ".
      -- No searched_as for a refused user: the bridge did not search as anybody.
      apex_debug.warn(c_scope_prefix || 'search: %s', sqlerrm); -- @dblinter ignore(g-5080): an expected refusal of the bridge, not a failure; its message is all there is to log
      return status_json('error', p_collection_name
        , regexp_substr(sqlerrm, '^ORA-[0-9]+: ([^' || chr(10) || ']*)', 1, 1, null, 1) -- @dblinter ignore(g-5080): the message of the bridge is written for the user; no backtrace goes into a tool answer
          || ' Tell the user that the search is unavailable.'
        , case when sqlcode != aic_rag_bridge_api.c_err_user_refused then l_user end);
    when others then
      apex_debug.error(c_scope_prefix || 'search: %s - %s', sqlerrm, sys.dbms_utility.format_error_backtrace);
      return status_json('error', p_collection_name, 'The search failed. Tell the user that the search is unavailable.', l_user);
  end search_passages_json;

  function search (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return clob
  as
  begin
    return search_passages_json(p_collection_name, p_query, null);
  end search;

  function search_as_app_user (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return clob
  as
    l_app_user varchar2(255 char);
  begin
    -- The APEX user of the session: the user that the application signed in. In a page and in a
    -- tool run of the agent this is the same session.
    l_app_user := sys_context('APEX$SESSION', 'APP_USER');
    if l_app_user is null or l_app_user = 'nobody' then
      return status_json('error', p_collection_name
        , 'No user is signed in, so no documents can be searched. Tell the user that the search is unavailable.', null);
    end if;
    return search_passages_json(p_collection_name, p_query, l_app_user);
  end search_as_app_user;

  function parse_query (
    p_parameters in clob
  ) return varchar2
  as
    l_json json_object_t;
  begin
    l_json := json_object_t.parse(nvl(p_parameters, '{}'));
    if l_json.has('query') and l_json.get('query').is_string then
      return substr(l_json.get_string('query'), 1, 4000);
    end if;
    return null;
  exception
    when others then -- @dblinter ignore(g-5040): whatever is wrong with the parameters, the result is the same: a missing query, and search() tells the model what to do
      return null;
  end parse_query;

  function search_contracts (
    p_parameters in clob
  ) return clob
  as
  begin
    return search('aic_contracts', parse_query(p_parameters));
  end search_contracts;

  function search_policies (
    p_parameters in clob
  ) return clob
  as
  begin
    return search('aic_policies', parse_query(p_parameters));
  end search_policies;

  function search_contracts_as_app_user (
    p_parameters in clob
  ) return clob
  as
  begin
    return search_as_app_user('aic_contracts', parse_query(p_parameters));
  end search_contracts_as_app_user;

  function search_policies_as_app_user (
    p_parameters in clob
  ) return clob
  as
  begin
    return search_as_app_user('aic_policies', parse_query(p_parameters));
  end search_policies_as_app_user;

end aic_app_tools_api;
/
