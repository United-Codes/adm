create or replace package body aic_rag_tools_api as
  pragma serially_reusable;

  c_scope_prefix constant varchar2(30 char) := 'aic_rag_tools_api.';

  -- A tool never raises, so every answer is built here. json_object_t takes care of quotes and
  -- newlines in the values, which hand-built JSON strings do not.
  function status_json (
    p_status     in varchar2
  , p_collection in varchar2 default null
  , p_message    in varchar2 default null
  , p_user       in varchar2 default null
  ) return clob
  as
    l_json json_object_t := json_object_t();
  begin
    l_json.put('status', p_status);
    if p_collection is not null then
      l_json.put('collection', p_collection);
    end if;
    if p_user is not null then
      l_json.put('searched_as', p_user);
    end if;
    if p_message is not null then
      l_json.put('message', p_message);
    end if;
    return l_json.to_clob();
  end status_json;

  function search (
    p_collection_name in varchar2
  , p_query           in varchar2
  , p_max_sources     in number default null
  , p_limit           in number default null
  , p_score_threshold in number default null
  ) return clob
  as
    l_user       varchar2(255 char);
    l_collection adm_ai_rag_collections.rag_collection_id%type;
    l_passages   clob;
  begin
    if p_query is null or trim(p_query) is null then
      return status_json('error', p_collection_name, 'The parameter "query" is required. Call the tool again with a query.');
    end if;

    -- Identity first. With no user the search below returns zero rows without an error, which
    -- would be reported as "no passages found" and explained to the user as a permission result.
    l_user := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username);
    if l_user is null then
      apex_debug.warn(c_scope_prefix || 'search: no ADM user in the session context');
      return status_json('no_identity', p_collection_name
        , 'No user is signed in on this connection, so no documents can be searched. This is a system fault, not an empty result. Tell the user that the search is unavailable.');
    end if;

    begin
      select rag_collection_id
        into l_collection
        from adm_ai_rag_collections
       where collection_name = p_collection_name;
    exception
      when no_data_found then
        return status_json('error', p_collection_name, 'This collection does not exist. Tell the user that the search is unavailable.', l_user);
    end;

    -- prepare_sources applies the access check of the current user to every chunk.
    select json_arrayagg(
             json_object(
               'document'       value document_name
             , 'score'          value round(avg_score, 3)
             , 'matched_chunks' value chunk_count
             , 'text'           value source_text
               returning clob
             )
             order by avg_score desc
             returning clob
           )
      into l_passages
      from table(
             adm_ai_rag_api.prepare_sources(
               p_rag_collection_id => l_collection
             , p_query             => p_query
             , p_limit             => p_limit
             , p_score_threshold   => p_score_threshold
             , p_max_sources       => p_max_sources
             )
           );

    if l_passages is null then
      return status_json('no_passages', p_collection_name
        , 'No passage in the collection ' || p_collection_name || ' matches this query. Say so; do not answer from memory. You may try other words.'
        , l_user);
    end if;

    declare
      l_json json_object_t := json_object_t();
    begin
      l_json.put('status', 'ok');
      l_json.put('collection', p_collection_name);
      l_json.put('searched_as', l_user);
      l_json.put('passages', json_array_t.parse(l_passages));
      return l_json.to_clob();
    end;
  exception
    when others then
      -- Details go to the debug log. The answer is read by the model and then by a person.
      apex_debug.error(c_scope_prefix || 'search: %s - %s', sqlerrm, sys.dbms_utility.format_error_backtrace);
      return status_json('error', p_collection_name, 'The search failed. Tell the user that the search is unavailable.', l_user);
  end search;

  function parse_query (
    p_parameters in clob
  , po_max_sources out nocopy number -- @dblinter ignore(g-7440): the package keeps no state, so the max_sources value comes back through the out parameter beside the query text
  ) return varchar2
  as
    l_json json_object_t;
  begin
    po_max_sources := null;
    l_json := json_object_t.parse(nvl(p_parameters, '{}'));
    if l_json.has('max_sources') and not l_json.get('max_sources').is_null then
      if l_json.get('max_sources').is_number then
        po_max_sources := l_json.get_number('max_sources');
      end if;
      if po_max_sources <= 0 then
        po_max_sources := null;
      end if;
    end if;
    if l_json.has('query') and l_json.get('query').is_string then
      return substr(l_json.get_string('query'), 1, 4000);
    end if;
    return null;
  exception
    when others then -- @dblinter ignore(g-5040): whatever is wrong with the parameters, the result is the same: a missing query, and search() tells the model what to do
      -- not JSON at all: treated like a missing query, search() says what to do
      return null;
  end parse_query;

  function search_contracts (
    p_parameters in clob
  ) return clob
  as
    l_max_sources number;
    l_query       varchar2(4000 char);
  begin
    l_query := parse_query(p_parameters, l_max_sources);
    return search('aic_contracts', l_query, l_max_sources);
  end search_contracts;

  function search_policies (
    p_parameters in clob
  ) return clob
  as
    l_max_sources number;
    l_query       varchar2(4000 char);
  begin
    l_query := parse_query(p_parameters, l_max_sources);
    return search('aic_policies', l_query, l_max_sources);
  end search_policies;

end aic_rag_tools_api;
/
