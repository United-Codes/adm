-- Prerequisite check for the "Ask questions across your documents" course.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner:
--
--   @00_precheck.sql
--
-- Six checks, each with the fix for a failure. Checks 5 and 6 call OpenAI with a few tokens
-- each (one embedding, one short answer). It changes no data.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

prompt
prompt ==========================================================
prompt  Ask questions across your documents - prerequisite check
prompt ==========================================================
prompt

-- ---------------------------------------------------------------------------
-- 1. Oracle Database 23ai or later (native vector store)
-- ---------------------------------------------------------------------------
declare
  l_version varchar2(100 char);
  l_major   number;
begin
  select version_full into l_version from product_component_version where rownum = 1;
  l_major := to_number(regexp_substr(l_version, '^\d+'));
  if l_major >= 23 then
    sys.dbms_output.put_line('1. OK: Oracle Database ' || l_version || ' has the native vector store.');
  else
    sys.dbms_output.put_line('1. FAILED: Oracle Database ' || l_version || ' has no native vector store.');
    sys.dbms_output.put_line('   Fix: this course needs 23ai or 26ai. (ADM also supports an external Qdrant, but this course does not use it.)');
  end if;
exception
  when others then
    sys.dbms_output.put_line('1. FAILED: could not read the database version: ' || substr(sqlerrm, 1, 200)); -- @dblinter ignore(g-5080): the message is the diagnosis this check exists to give, a backtrace of a probe would only confuse the reader
end;
/

-- ---------------------------------------------------------------------------
-- 2. The AI Pack and UC AI are installed
-- ---------------------------------------------------------------------------
declare
  l_invalid pls_integer;
  l_version varchar2(16 char);
  c_get_version constant varchar2(100 char) := 'begin :1 := uc_ai.c_version; end;';
begin
  select count(*)
    into l_invalid
    from user_objects
   where object_name in ('ADM_AI_RAG_API', 'ADM_AI_RAG_WORKFLOW_API', 'ADM_AI_AGENT_TOOLS_API', 'UC_AI', 'UC_AI_AGENTS_API')
     and status != 'VALID';
  execute immediate c_get_version using out l_version;
  if l_invalid = 0 then
    sys.dbms_output.put_line('2. OK: the AI Pack is installed. UC AI version ' || l_version || '.');
  else
    sys.dbms_output.put_line('2. FAILED: ' || l_invalid || ' AI Pack package(s) are invalid. Recompile them.');
  end if;
exception
  when others then
    sys.dbms_output.put_line('2. FAILED: the AI Pack is not installed in this schema.');
    sys.dbms_output.put_line('   Fix: run install_ai.sql after install.sql. See the AI Pack installation guide.');
end;
/

-- ---------------------------------------------------------------------------
-- 3. The roles exist and you may act as the system user
-- ---------------------------------------------------------------------------
declare
  l_role number;
begin
  select role_id into l_role from adm_roles where role_name = 'CONTRIBUTOR';
  adm_context_api.system_login;
  adm_context_api.clear_context;   -- the check only: the session does not stay the system user
  sys.dbms_output.put_line('3. OK: the role CONTRIBUTOR exists and adm_context_api.system_login works.');
exception
  when others then
    adm_context_api.clear_context;
    sys.dbms_output.put_line('3. FAILED: ' || substr(sqlerrm, 1, 200)); -- @dblinter ignore(g-5080): the message is the diagnosis this check exists to give, a backtrace of a probe would only confuse the reader
end;
/

-- ---------------------------------------------------------------------------
-- 4. The web credential exists in the workspace of this schema
-- ---------------------------------------------------------------------------
declare
  l_workspace apex_workspaces.workspace%type;
  l_exists    number;
begin
  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
  if l_workspace is null then
    sys.dbms_output.put_line('4. FAILED: this schema is not assigned to any APEX workspace.');
    return;
  end if;
  apex_util.set_workspace(l_workspace);
  select case when exists (select 1 from apex_workspace_credentials where static_id = 'OPENAI') then 1 else 0 end
    into l_exists
    from dual;
  if l_exists = 0 then
    sys.dbms_output.put_line('4. FAILED: workspace ' || l_workspace || ' has no web credential with the static id OPENAI.');
    sys.dbms_output.put_line('   Fix: in APEX go to Workspace Utilities > Web Credentials and create one named OPENAI');
    sys.dbms_output.put_line('   (type HTTP Header, header Authorization, value "Bearer <your key>").');
  else
    sys.dbms_output.put_line('4. OK: workspace ' || l_workspace || ' has the web credential OPENAI.');
  end if;
end;
/

-- ---------------------------------------------------------------------------
-- 5. The embedding model answers, and has the dimensions the collections will use
-- ---------------------------------------------------------------------------
declare
  l_vectors   json_array_t;
  l_workspace apex_workspaces.workspace%type;
begin
  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
  apex_util.set_workspace(l_workspace);
  l_vectors := uc_ai.generate_embeddings(
    p_input    => json_array_t('["notice period"]')
  , p_provider => 'openai'
  , p_model    => 'text-embedding-3-small'
  , p_config   => json_object_t('{"g_apex_web_credential":"OPENAI"}')
  );
  sys.dbms_output.put_line('5. OK: text-embedding-3-small answered with '
    || treat(l_vectors.get(0) as json_array_t).get_size || ' dimensions (the collections use 1536).');
exception
  when others then
    sys.dbms_output.put_line('5. FAILED: the embedding call did not work.');
    sys.dbms_output.put_line('   Error: ' || substr(sqlerrm, 1, 300)); -- @dblinter ignore(g-5080): the message is the diagnosis this check exists to give, a backtrace of a probe would only confuse the reader
    sys.dbms_output.put_line('   ORA-24247  no network ACL: a DBA must allow this schema to reach api.openai.com on port 443.');
    sys.dbms_output.put_line('   ORA-29024  certificate not trusted: the OpenAI certificate chain must be in the database wallet.');
    sys.dbms_output.put_line('   HTTP 401   the key in the web credential is wrong or has expired.');
end;
/

-- ---------------------------------------------------------------------------
-- 6. The answer model answers
-- ---------------------------------------------------------------------------
declare
  l_result    json_object_t;
  l_workspace apex_workspaces.workspace%type;
begin
  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
  apex_util.set_workspace(l_workspace);
  l_result := uc_ai.generate_text(
    p_user_prompt => 'Reply with the single word OK.'
  , p_provider    => 'openai'
  , p_model       => 'gpt-6.1-sol'
  , p_config      => json_object_t('{"g_apex_web_credential":"OPENAI"}')
  );
  sys.dbms_output.put_line('6. OK: gpt-6.1-sol answered "' || substr(l_result.get_clob('final_message'), 1, 40)
    || '" (' || l_result.get_object('usage').get_number('total_tokens') || ' tokens).');
exception
  when others then
    sys.dbms_output.put_line('6. FAILED: the call to the answer model did not work.');
    sys.dbms_output.put_line('   Error: ' || substr(sqlerrm, 1, 300)); -- @dblinter ignore(g-5080): the message is the diagnosis this check exists to give, a backtrace of a probe would only confuse the reader
    sys.dbms_output.put_line('   Another model works too: change it in 03_aic_collections.sql and 08_aic_register.sql.');
end;
/

-- ---------------------------------------------------------------------------
-- Things to know, not checks
-- ---------------------------------------------------------------------------
declare
  l_hooks number;
  l_ocr   adm_settings.sett_value%type;
begin
  select count(*) into l_hooks from adm_hooks;
  sys.dbms_output.put_line('Note: ' || l_hooks || ' ADM hook(s) are registered in this schema. The course uploads use p_run_hooks => false,');
  sys.dbms_output.put_line('      so no hook runs on the sample files.');
  select sett_value into l_ocr from adm_settings where sett_key = 'AI_TEXT_EXTRACTION';
  sys.dbms_output.put_line('Note: AI_TEXT_EXTRACTION = ' || nvl(l_ocr, '(empty)')
    || '. The scanned sample needs Y, because only then are scanned files sent to a model.');
end;
/

prompt
prompt If checks 1 to 6 say OK, install the course objects with install.sql.
set feedback on
