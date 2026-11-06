-- Lesson 7: what the bridge does, called directly, without a model. Run as the ADM schema owner,
-- after 24_aic_bridge_setup.sql. About 12 search embeddings and one embedding call that fails on
-- purpose (section "A failure inside the search"). No answer model.
--
--   sql -name <connection> @25_aic_bridge_check.sql
--
-- It runs in the ADM schema because only here can a script set an ADM user for the caller, which
-- shows that the bridge gives that user back. The application schema cannot set one at all.
-- Nothing is committed, and the session ends with no ADM user.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off
set linesize 200
alter session set nls_numeric_characters = '.,';

declare
  c_contracts constant varchar2(30 char) := 'aic_contracts';
  c_policies  constant varchar2(30 char) := 'aic_policies';
  c_helios    constant varchar2(200 char) := 'Helios exclusive distribution notice period';
  c_salary    constant varchar2(200 char) := 'salary band senior engineer';
  l_admin     adm_users.username%type;

  procedure say (
    p_text in varchar2 default null
  )
  as
  begin
    sys.dbms_output.put_line(p_text);
  end say;

  function context_text
    return varchar2
  as
  begin
    return nvl(sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_username), '(none)')
        || ' / ' || nvl(sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_role), '-')
        || ' / ' || nvl(sys_context(adm_context_api.c_ctx_namespace, adm_context_api.c_ctx_access_source), '-');
  end context_text;

  -- the passages of prepare_sources for the ADM user of the session (or for nobody)
  function direct_result (
    p_collection in varchar2
  , p_query      in varchar2
  ) return varchar2
  as
    l_id   adm_ai_rag_collections.rag_collection_id%type;
    l_text varchar2(4000 char);
  begin
    select rag_collection_id into l_id from adm_ai_rag_collections where collection_name = p_collection;
    select count(*) || ' rows ' || listagg(document_name, ', ') within group (order by avg_score desc)
      into l_text
      from table(adm_ai_rag_api.prepare_sources(p_rag_collection_id => l_id, p_query => p_query));
    return l_text;
  end direct_result;

  function bridge_result (
    p_collection in varchar2
  , p_query      in varchar2
  ) return varchar2
  as
    l_text varchar2(4000 char);
  begin
    select count(*) || ' rows ' || listagg(document_name || ' (' || round(score, 3) || ')', ', ') within group (order by score desc)
      into l_text
      from table(aic_rag_bridge_api.search_passages(p_collection_name => p_collection, p_query => p_query));
    return l_text;
  exception
    when others then -- @dblinter ignore(g-5040): the script prints the error of the bridge as its result, so the reader sees each refusal
      -- the first line of the error, without the response body of a failed provider call
      l_text := regexp_substr(sqlerrm, '^[^' || chr(10) || ']*'); -- @dblinter ignore(g-5080): the error is the printed result here, not a failure to log
      return 'error ' || substr(l_text, 1, instr(l_text || ', response', ', response') - 1);
  end bridge_result;

  function user_result (
    p_username   in varchar2
  , p_collection in varchar2
  , p_query      in varchar2
  ) return varchar2
  as
    l_text varchar2(4000 char);
  begin
    select count(*) || ' rows ' || listagg(document_name, ', ') within group (order by score desc)
      into l_text
      from table(aic_rag_bridge_api.search_passages_for_user(p_username => p_username, p_collection_name => p_collection, p_query => p_query));
    return l_text;
  exception
    when others then -- @dblinter ignore(g-5040): the script prints the error of the bridge as its result, so the reader sees each refusal
      return 'error ' || regexp_substr(sqlerrm, '^[^' || chr(10) || ']*'); -- @dblinter ignore(g-5080): the error is the printed result here, not a failure to log
  end user_result;
begin
  say('--- prepare_sources without an ADM user ---');
  adm_context_api.clear_context;
  say('context:                ' || context_text);
  say('prepare_sources:        ' || direct_result(c_contracts, 'Alpenwerk notice period termination'));
  adm_context_api.system_user_login('AIC_SERVICE');
  say('context:                ' || context_text);
  say('prepare_sources:        ' || direct_result(c_contracts, 'Alpenwerk notice period termination'));

  say;
  say('--- The bridge searches as AIC_SERVICE, whoever calls it ---');
  adm_context_api.system_user_login('AIC_HR');
  say('caller:                 ' || context_text);
  say('Helios, direct:         ' || direct_result(c_contracts, c_helios));
  say('Helios, bridge:         ' || bridge_result(c_contracts, c_helios));
  say('salary bands, direct:   ' || direct_result(c_policies, c_salary));
  say('salary bands, bridge:   ' || bridge_result(c_policies, c_salary));
  say('caller after the calls: ' || context_text);

  say;
  say('--- The bridge refuses names outside its prefix ---');
  say('hr_salaries:            ' || bridge_result('hr_salaries', c_salary));
  say('caller after the error: ' || context_text);

  say;
  say('--- A name that does not exist ---');
  say('aic_handbook:           ' || bridge_result('aic_handbook', 'notice period'));
  say('caller after the error: ' || context_text);

  say;
  say('--- A failure inside the search ---');
  -- An empty query fails at the embedding call, AFTER the bridge has logged in as AIC_SERVICE.
  say('empty query:            ' || bridge_result(c_policies, null));
  say('caller after the error: ' || context_text);

  say;
  say('--- A caller that stops after the first row ---');
  <<first_row>>
  for r in (
    select document_name
      from table(aic_rag_bridge_api.search_passages(p_collection_name => c_contracts, p_query => 'Alpenwerk notice period termination'))
     fetch first 1 row only
  ) loop
    say('first row:              ' || r.document_name);
  end loop first_row;
  say('caller after the fetch: ' || context_text);

  say;
  say('--- The per-user function gives the caller back, too ---');
  -- an ADM administrator of this schema, whoever it is: the bridge must refuse every one
  select min(u.username)
    into l_admin
    from adm_users u
    join adm_roles r
      on r.role_id = u.role_id
   where r.role_name = 'ADMIN'
     and u.is_active = 'Y';
  say('AIC_LEGAL, salary bands: ' || user_result('AIC_LEGAL', c_policies, c_salary));
  say('AIC_HR, salary bands:    ' || user_result('AIC_HR', c_policies, c_salary));
  say(rpad(l_admin || ':', 25) || user_result(l_admin, c_policies, c_salary));
  say('caller after the calls:  ' || context_text);

  rollback;
  adm_context_api.clear_context;
end;
/
set feedback on
