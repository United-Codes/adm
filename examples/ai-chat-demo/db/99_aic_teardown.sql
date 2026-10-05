-- Removes everything the course created. Run as the ADM schema owner. Re-runnable: what is
-- already gone is skipped.
--
--   sql -name <connection> @99_aic_teardown.sql
--
-- What goes, in this order:
--   1. the agent runs: the history of aic_assistant, and every run and memory of AIC_LEGAL and
--      AIC_HR with other agents (the bundled adm_doc_assistant keeps a memory store per user)
--   2. the UC AI objects: agent, prompt profile, tools
--   3. the RAG collections aic_contracts and aic_policies, with their chunks and their vectors
--      (adm_ai_rag_api.delete_rag_collection drops the vector table)
--   4. the documents and folders under /groups/aic_legal and /groups/aic_hr, with their shares
--   5. the groups AIC_LEGAL and AIC_HR, the users AIC_LEGAL and AIC_HR and their home folders
--   6. the objects of this course: tables aic_*, packages aic_*
--   7. the APEX accounts AIC_LEGAL and AIC_HR (db/18_aic_apex_users.sql) in the workspace of this schema
--      (the chat app itself, application 218, is not removed: delete it in the App Builder)
--
-- What stays: the audit log of ADM (adm_audit_log) and the debug log keep their entries about
-- these users. An audit trail that loses entries when a user is deleted is not an audit trail.
-- Folder creation fires the hook AFTER_NEW_FOLDER_CREATION when ADM creates a group or a user's
-- home folder; ADM has no switch to skip it there. If another course registered that hook,
-- its worker leaves a SKIPPED row for these folders in its own tables, which this script does not touch.
--
-- ADM has no API to delete a user or a group. Step 5 deletes their rows directly, which is only
-- safe because nothing else refers to them any more after steps 1 to 4.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set define off
set serveroutput on
set feedback off

-- 1 and 2: agent history, memory, agent, profile, tools --------------------------------------
declare
  l_n number;
begin
  -- runs and memory of the two demo users with ANY agent (the bundled one writes a memory per user)
  delete from uc_ai_agent_messages m
   where m.execution_id in (select e.id from uc_ai_agent_executions e where e.created_by in ('AIC_LEGAL', 'AIC_HR'));
  delete from uc_ai_agent_executions where created_by in ('AIC_LEGAL', 'AIC_HR');
  delete from uc_ai_agent_sessions   where created_by in ('AIC_LEGAL', 'AIC_HR');
  delete from uc_ai_memory_files f
   where f.store_id in (select s.id from uc_ai_memory_stores s where s.username in ('AIC_LEGAL', 'AIC_HR'));
  delete from uc_ai_memory_stores where username in ('AIC_LEGAL', 'AIC_HR');
  commit;

  select count(*) into l_n from uc_ai_agents where code = 'aic_assistant';
  if l_n > 0 then
    uc_ai_agents_api.purge_agent('aic_assistant');   -- every version, all runs, sessions and memory
    commit;
  end if;

  select count(*) into l_n from uc_ai_prompt_profiles where code = 'AIC_ASSISTANT';
  if l_n > 0 then
    delete from uc_ai_prompt_profiles where code = 'AIC_ASSISTANT';
    commit;
  end if;

  delete from uc_ai_tools where code like 'AIC\_%' escape '\';   -- parameters and tags cascade
  commit;
  sys.dbms_output.put_line('1-2. agent history, agent, prompt profile and tools removed');
end;
/

-- 3: collections --------------------------------------------------------------------------------
begin
  adm_context_api.system_login;
  <<collection_loop>>
  for c in (select collection_name from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
    adm_ai_rag_api.delete_rag_collection(p_collection_name => c.collection_name);
    sys.dbms_output.put_line('3. collection removed: ' || c.collection_name);
  end loop collection_loop;
  commit;
end;
/

-- 4: documents and folders ----------------------------------------------------------------------
declare
  -- A document must go to a trash folder before it can be deleted for good, and the system user has
  -- none. The demo user AIC_LEGAL does, until step 5 removes it.
  c_trash_user constant varchar2(255 char) := 'AIC_LEGAL';
begin
  adm_context_api.system_login;

  <<document_loop>>
  for d in (
    select doc.document_id
      from adm_documents doc
      join adm_folders f on f.folder_id = doc.folder_id
     where f.folder_path like '/groups/aic\_%' escape '\'
        or f.folder_path like '/users/aic\_%'  escape '\'
  ) loop
    adm_document_api.trash_document(p_document_id => d.document_id, p_user_id => c_trash_user);
    adm_document_api.permanently_delete_document(p_document_id => d.document_id);
  end loop document_loop;
  commit;
  sys.dbms_output.put_line('4. documents removed');
end;
/

-- 5: groups, users, folders ----------------------------------------------------------------------
declare
begin
  adm_context_api.system_login;

  -- shares that still name the demo users or groups (folder shares; document shares went with the documents)
  delete from adm_document_shares s
   where s.shared_with_user_id  in (select u.user_id  from adm_users  u where u.username   in ('AIC_LEGAL', 'AIC_HR'))
      or s.shared_with_group_id in (select g.group_id from adm_groups g where g.group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_folder_shares s
   where s.shared_with_user_id  in (select u.user_id  from adm_users  u where u.username   in ('AIC_LEGAL', 'AIC_HR'))
      or s.shared_with_group_id in (select g.group_id from adm_groups g where g.group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_group_members m
   where m.group_id in (select g.group_id from adm_groups g where g.group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_groups where group_name in ('AIC_LEGAL', 'AIC_HR');

  -- folders: the group folders, then the home and trash folder of each user
  <<folder_loop>>
  for f in (
    select folder_id
      from adm_folders
     where folder_path like '/groups/aic\_%' escape '\'
        or folder_path like '/users/aic\_%'  escape '\'
     order by length(folder_path) desc
  ) loop
    delete from adm_folders where folder_id = f.folder_id; -- @dblinter ignore(g-3210): the folders must go one at a time, the deepest path first, so that no folder is deleted before its children
  end loop folder_loop;

  delete from adm_users where username in ('AIC_LEGAL', 'AIC_HR');   -- the cache rows cascade
  commit;
  sys.dbms_output.put_line('5. groups, users and folders removed');
end;
/

-- 6: the objects of this course --------------------------------------------------------------------
declare
  procedure drop_if_exists (p_type in varchar2, p_name in varchar2) as
    l_exists number;
    l_ddl    varchar2(200 char);
  begin
    select case when exists (select 1 from user_objects o where o.object_type = p_type and o.object_name = upper(p_name)) then 1 else 0 end
      into l_exists
      from dual;
    if l_exists > 0 then
      l_ddl := 'drop ' || p_type || ' ' || p_name || case when p_type = 'TABLE' then ' purge' end; -- @dblinter ignore(g-9501): p_type and p_name are literals of this script, never user input
      execute immediate l_ddl;
    end if;
  end drop_if_exists;
begin
  drop_if_exists('PACKAGE', 'aic_agent_api');
  drop_if_exists('PACKAGE', 'aic_rag_tools_api');
  drop_if_exists('TABLE',   'aic_questions');
  sys.dbms_output.put_line('6. packages and tables removed');
end;
/

-- 7: the APEX accounts of the chat page -----------------------------------------------------------
declare
  l_workspace apex_workspaces.workspace%type;
begin
  select min(workspace_name) into l_workspace from apex_workspace_schemas where schema = user;
  if l_workspace is not null then
    apex_util.set_workspace(l_workspace);
    <<remove_accounts>>
    for u in (
      select au.user_name
        from apex_workspace_apex_users au
       where au.workspace_name = l_workspace
         and au.user_name in ('AIC_LEGAL', 'AIC_HR')
    ) loop
      apex_util.remove_user(p_user_name => u.user_name);
      sys.dbms_output.put_line('7. APEX account removed: ' || u.user_name); -- @dblinter ignore(g-5010): script output for the person who runs it
    end loop remove_accounts;
    commit;
  end if;
end;
/

prompt
prompt What is left with an aic prefix (every count must be 0):
select 'adm_users'             as what, count(*) as n from adm_users where username like 'AIC\_%' escape '\'
union all select 'adm_groups',          count(*) from adm_groups where group_name like 'AIC\_%' escape '\'
union all select 'adm_folders',         count(*) from adm_folders where folder_path like '/groups/aic\_%' escape '\' or folder_path like '/users/aic\_%' escape '\'
union all select 'adm_documents',       count(*) from adm_documents d join adm_folders f on f.folder_id = d.folder_id where f.folder_path like '/groups/aic\_%' escape '\'
union all select 'rag collections',     count(*) from adm_ai_rag_collections where collection_name like 'aic\_%' escape '\'
union all select 'orphan vector tables', count(*) from user_tables where table_name like 'ADM\_AI\_RAG\_VEC\_%' escape '\' and to_number(regexp_substr(table_name, '\d+$')) not in (select c.rag_collection_id from adm_ai_rag_collections c)
union all select 'uc_ai agents',        count(*) from uc_ai_agents where code like 'aic\_%' escape '\'
union all select 'uc_ai profiles',      count(*) from uc_ai_prompt_profiles where code like 'AIC\_%' escape '\'
union all select 'uc_ai tools',         count(*) from uc_ai_tools where code like 'AIC\_%' escape '\'
union all select 'uc_ai executions',    count(*) from uc_ai_agent_executions where created_by like 'AIC\_%' escape '\'
union all select 'uc_ai memory stores', count(*) from uc_ai_memory_stores where username like 'AIC\_%' escape '\'
union all select 'aic objects',         count(*) from user_objects where object_name like 'AIC\_%' escape '\'
union all select 'apex accounts',       count(*) from apex_workspace_apex_users where user_name in ('AIC_LEGAL', 'AIC_HR');
set feedback on
