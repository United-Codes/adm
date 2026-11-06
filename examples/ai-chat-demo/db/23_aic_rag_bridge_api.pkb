create or replace package body aic_rag_bridge_api as

  c_scope_prefix constant varchar2(30 char) := 'aic_rag_bridge_api.';

  -- The ADM context of a session: what the bridge puts back before a row leaves it.
  type r_context_type is record (
    username      varchar2(255 char)
  , role          varchar2(30 char)
  , access_source varchar2(30 char)
  );

  -- The collections that the bridge can search, for the message of a name that does not exist.
  -- Only names with the prefix: the other schema learns nothing about other collections.
  function allowed_names
    return varchar2
  as
    l_names varchar2(4000 char);
  begin
    select listagg(c.collection_name, ', ' on overflow truncate) within group (order by c.collection_name)
      into l_names
      from adm_ai_rag_collections c
     where substr(c.collection_name, 1, length(c_collection_prefix)) = c_collection_prefix;
    return nvl(l_names, '(none)');
  end allowed_names;

  -- The name check and the lookup. A literal comparison, because "_" in a like pattern matches any
  -- character.
  function collection_id (
    p_collection_name in varchar2
  ) return adm_ai_rag_collections.rag_collection_id%type
  as
    l_id adm_ai_rag_collections.rag_collection_id%type;
  begin
    if p_collection_name is null
       or substr(p_collection_name, 1, length(c_collection_prefix)) != c_collection_prefix
    then
      adm_error.raise_error(
        p_error_code => c_err_collection_refused
      , p_message    => c_msg_collection_refused
      , p_scope      => c_scope_prefix || 'collection_id'
      , p0           => c_collection_prefix
      , p1           => p_collection_name
      );
    end if;

    select rag_collection_id
      into l_id
      from adm_ai_rag_collections
     where collection_name = p_collection_name;
    return l_id;
  exception
    when no_data_found then
      adm_error.raise_error(
        p_error_code => c_err_collection_not_found
      , p_message    => c_msg_collection_not_found
      , p_scope      => c_scope_prefix || 'collection_id'
      , p0           => p_collection_name
      , p1           => allowed_names
      );
  end collection_id;

  procedure refuse_user (
    p_username in varchar2
  , p_reason   in varchar2
  )
  as
  begin
    adm_error.raise_error(
      p_error_code => c_err_user_refused
    , p_message    => c_msg_user_refused
    , p_scope      => c_scope_prefix || 'check_user'
    , p0           => p_username
    , p1           => p_reason
    );
  end refuse_user;

  -- The guards of search_passages_for_user. They run in the ADM schema, so the other schema cannot
  -- skip them.
  procedure check_user (
    p_username in varchar2
  )
  as
    l_active   pls_integer;
    l_admin    pls_integer;
    l_in_group pls_integer;
    l_groups   apex_t_varchar2 := c_allowed_groups;
  begin
    select count(*)
         , count(case when r.role_name = 'ADMIN' then 1 end)
      into l_active
         , l_admin
      from adm_users u
      join adm_roles r
        on r.role_id = u.role_id
     where u.username  = upper(p_username)
       and u.is_active = 'Y';

    if l_active = 0 then
      refuse_user(p_username, 'no active ADM user has this name');
    elsif l_admin > 0 then
      refuse_user(p_username, 'the user has the role ADMIN');
    end if;

    select case
             when exists (
                    select 1
                      from adm_group_members m
                      join adm_groups g
                        on g.group_id = m.group_id
                      join adm_users u
                        on u.user_id = m.user_id
                     where u.username = upper(p_username)
                       and g.group_name in (select a.column_value from table(l_groups) a)
                  )
             then 1
             else 0
           end
      into l_in_group
      from dual;

    if l_in_group = 0 then
      refuse_user(p_username, 'the user is in none of the groups ' || apex_string.join(c_allowed_groups, ', '));
    end if;
  end check_user;

  -- Puts the ADM context of the caller back. If that fails, the session is left with no ADM user,
  -- not with the identity of the bridge.
  procedure restore_caller (
    p_caller in r_context_type
  )
  as
  begin
    adm_context_api.restore_context(
      p_username      => p_caller.username
    , p_role          => p_caller.role
    , p_access_source => p_caller.access_source
    );
  exception
    when others then
      adm_error.log_error(p_scope => c_scope_prefix || 'restore_caller');
      adm_context_api.clear_context;
      raise;
  end restore_caller;

  -- Reads every passage as p_username, then gives the caller its own ADM context back.
  function fetch_as (
    p_username      in varchar2
  , p_collection_id in adm_ai_rag_collections.rag_collection_id%type
  , p_query         in varchar2
  ) return t_passages
  as
    l_caller   r_context_type;
    l_passages t_passages;
  begin
    l_caller.username      := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username);
    l_caller.role          := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_role);
    l_caller.access_source := sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_access_source);

    apex_debug.info('%sfetch_as: collection %s as %s, caller %s', c_scope_prefix, p_collection_id, p_username, nvl(l_caller.username, '(none)'));

    begin
      adm_context_api.system_user_login(p_username => p_username);

      -- Also for the fixed user: if an administrator gives it the role ADMIN, the bridge stops.
      if sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_role) = adm_context_api.c_role_admin then
        refuse_user(p_username, 'the user has the role ADMIN');
      end if;

      -- bulk collect reads every row while the identity is held
      select document_name
           , avg_score
           , chunk_count
           , source_text
        bulk collect into l_passages
        from table(
               adm_ai_rag_api.prepare_sources(
                 p_rag_collection_id => p_collection_id
               , p_query             => p_query
               )
             )
       order by avg_score desc;
    exception
      when others then
        -- Log the original error first. If restore_caller fails too, its error is the one that
        -- leaves this function, and the original is only in the log.
        adm_error.log_error(
          p_scope => c_scope_prefix || 'fetch_as'
        , p_extra => 'collection id ' || p_collection_id || ', user ' || p_username
        );
        restore_caller(l_caller);
        raise;
    end;

    restore_caller(l_caller);
    return l_passages;
  end fetch_as;

  function search_passages (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return t_passages pipelined
  as
    l_passages t_passages;
  begin
    l_passages := fetch_as(
                    p_username      => c_service_user
                  , p_collection_id => collection_id(p_collection_name)
                  , p_query         => p_query
                  );

    -- The rows, only after the identity of the caller is back.
    <<pipe_passages>>
    for i in 1 .. l_passages.count loop
      pipe row (l_passages(i));
    end loop pipe_passages;

    return;
  end search_passages;

  function search_passages_for_user (
    p_username        in varchar2
  , p_collection_name in varchar2
  , p_query           in varchar2
  ) return t_passages pipelined
  as
    l_collection_id adm_ai_rag_collections.rag_collection_id%type;
    l_passages      t_passages;
  begin
    l_collection_id := collection_id(p_collection_name);
    check_user(p_username);

    l_passages := fetch_as(
                    p_username      => upper(p_username)
                  , p_collection_id => l_collection_id
                  , p_query         => p_query
                  );

    <<pipe_passages>>
    for i in 1 .. l_passages.count loop
      pipe row (l_passages(i));
    end loop pipe_passages;

    return;
  end search_passages_for_user;

end aic_rag_bridge_api;
/
