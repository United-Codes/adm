-- Lesson 6: register the two search tools again, without the parameter max_sources. Costs nothing.
-- Run as the ADM schema owner, after 11_aic_second_tool.sql:
--
--   sql -name <connection> @21_aic_tools_without_max_sources.sql
--
-- Before this script, the JSON schema of both tools offered "max_sources", and the model passed 5 in
-- every call. A value that the caller passes wins over default_max_sources of the collection, so the
-- "Maximum sources" field in the RAG collection manager did not reach the agent. Without the
-- parameter the tool passes null, and the stored value of the collection applies.
--
-- The script keeps the description, the function call and the tag of each tool. It changes only the
-- parameters. 08_aic_register.sql and 11_aic_second_tool.sql register the tools with max_sources
-- again, so run this script again after either of them.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

declare
  l_tool_id uc_ai_tools.id%type;
begin
  <<tool_loop>>
  for t in (select code, description, function_call from uc_ai_tools where code in ('AIC_SEARCH_CONTRACTS', 'AIC_SEARCH_POLICIES') order by code) loop
    l_tool_id := uc_ai_tools_api.merge_tool_from_schema( -- @dblinter ignore(g-2135): merge_tool_from_schema is a function, and this script does not need the id
      p_tool_code        => t.code
    , p_description      => t.description
    , p_function_call    => t.function_call
    , p_json_schema      => json_object_t('{
        "type": "object",
        "properties": {
          "query": { "type": "string", "description": "What to look for. Key words, not a whole sentence." }
        },
        "required": ["query"]
      }')
    , p_tags             => apex_t_varchar2('aic_demo')
    , p_code_mode_access => 'direct'
    );
  end loop tool_loop;
  commit;
end;
/

prompt
prompt Parameters of the search tools now:
set linesize 120
column tool_code format a22
column parameters format a30
select t.code as tool_code
     , listagg(p.name, ', ') within group (order by p.name) as parameters
  from uc_ai_tools t
  join uc_ai_tool_parameters p on p.tool_id = t.id
 where t.code in ('AIC_SEARCH_CONTRACTS', 'AIC_SEARCH_POLICIES')
 group by tool_code
 order by tool_code;
set feedback on
