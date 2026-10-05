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
--
-- What stays: the audit log of ADM (adm_audit_log) and the debug log keep their entries about
-- these users. An audit trail that loses entries when a user is deleted is not an audit trail.
-- Folder creation fires the hook AFTER_NEW_FOLDER_CREATION when ADM creates a group or a user's
-- home folder; ADM has no switch to skip it there. If another course registered that hook,
-- its worker leaves a SKIPPED row for these folders in its own tables, which this script does not touch.
--
-- ADM has no API to delete a user or a group. Step 5 deletes their rows directly, which is only
-- safe because nothing else refers to them any more after steps 1 to 4.

set define off
set serveroutput on
set feedback off

-- 1 and 2: agent history, memory, agent, profile, tools --------------------------------------
declare
  l_n number;
begin
  -- runs and memory of the two demo users with ANY agent (the bundled one writes a memory per user)
  delete from uc_ai_agent_messages
   where execution_id in (select id from uc_ai_agent_executions where created_by in ('AIC_LEGAL', 'AIC_HR'));
  delete from uc_ai_agent_executions where created_by in ('AIC_LEGAL', 'AIC_HR');
  delete from uc_ai_agent_sessions   where created_by in ('AIC_LEGAL', 'AIC_HR');
  delete from uc_ai_memory_files
   where store_id in (select id from uc_ai_memory_stores where username in ('AIC_LEGAL', 'AIC_HR'));
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
  dbms_output.put_line('1-2. agent history, agent, prompt profile and tools removed');
end;
/

-- 3: collections --------------------------------------------------------------------------------
begin
  adm_context_api.system_login;
  for c in (select collection_name from adm_ai_rag_collections where collection_name in ('aic_contracts', 'aic_policies')) loop
    adm_ai_rag_api.delete_rag_collection(p_collection_name => c.collection_name);
    dbms_output.put_line('3. collection removed: ' || c.collection_name);
  end loop;
  commit;
end;
/

-- 4: documents and folders ----------------------------------------------------------------------
declare
  -- A document must go to a trash folder before it can be deleted for good, and the system user has
  -- none. The demo user AIC_LEGAL does, until step 5 removes it.
  l_trash_user constant varchar2(255 char) := 'AIC_LEGAL';
begin
  adm_context_api.system_login;

  for d in (
    select doc.document_id
      from adm_documents doc
      join adm_folders f on f.folder_id = doc.folder_id
     where f.folder_path like '/groups/aic\_%' escape '\'
        or f.folder_path like '/users/aic\_%'  escape '\'
  ) loop
    adm_document_api.trash_document(p_document_id => d.document_id, p_user_id => l_trash_user);
    adm_document_api.permanently_delete_document(p_document_id => d.document_id);
  end loop;
  commit;
  dbms_output.put_line('4. documents removed');
end;
/

-- 5: groups, users, folders ----------------------------------------------------------------------
declare
  l_n number;
begin
  adm_context_api.system_login;

  -- shares that still name the demo users or groups (folder shares; document shares went with the documents)
  delete from adm_document_shares
   where shared_with_user_id  in (select user_id  from adm_users  where username   in ('AIC_LEGAL', 'AIC_HR'))
      or shared_with_group_id in (select group_id from adm_groups where group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_folder_shares
   where shared_with_user_id  in (select user_id  from adm_users  where username   in ('AIC_LEGAL', 'AIC_HR'))
      or shared_with_group_id in (select group_id from adm_groups where group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_group_members
   where group_id in (select group_id from adm_groups where group_name in ('AIC_LEGAL', 'AIC_HR'));
  delete from adm_groups where group_name in ('AIC_LEGAL', 'AIC_HR');

  -- folders: the group folders, then the home and trash folder of each user
  for f in (
    select folder_id
      from adm_folders
     where folder_path like '/groups/aic\_%' escape '\'
        or folder_path like '/users/aic\_%'  escape '\'
     order by length(folder_path) desc
  ) loop
    delete from adm_folders where folder_id = f.folder_id;
  end loop;

  delete from adm_users where username in ('AIC_LEGAL', 'AIC_HR');   -- the cache rows cascade
  commit;
  dbms_output.put_line('5. groups, users and folders removed');
end;
/

-- 6: the objects of this course --------------------------------------------------------------------
declare
  procedure drop_if_exists (p_type in varchar2, p_name in varchar2) as
    l_count number;
  begin
    select count(*) into l_count from user_objects where object_type = p_type and object_name = upper(p_name);
    if l_count > 0 then
      execute immediate 'drop ' || p_type || ' ' || p_name || case when p_type = 'TABLE' then ' purge' else '' end;
    end if;
  end drop_if_exists;
begin
  drop_if_exists('PACKAGE', 'aic_agent_api');
  drop_if_exists('PACKAGE', 'aic_rag_tools_api');
  drop_if_exists('TABLE',   'aic_questions');
  dbms_output.put_line('6. packages and tables removed');
end;
/

prompt
prompt What is left with an aic prefix (every count must be 0):
select 'adm_users'             as what, count(*) as n from adm_users where username like 'AIC\_%' escape '\'
union all select 'adm_groups',          count(*) from adm_groups where group_name like 'AIC\_%' escape '\'
union all select 'adm_folders',         count(*) from adm_folders where folder_path like '/groups/aic\_%' escape '\' or folder_path like '/users/aic\_%' escape '\'
union all select 'adm_documents',       count(*) from adm_documents d join adm_folders f on f.folder_id = d.folder_id where f.folder_path like '/groups/aic\_%' escape '\'
union all select 'rag collections',     count(*) from adm_ai_rag_collections where collection_name like 'aic\_%' escape '\'
union all select 'orphan vector tables', count(*) from user_tables where table_name like 'ADM\_AI\_RAG\_VEC\_%' escape '\' and to_number(regexp_substr(table_name, '\d+$')) not in (select rag_collection_id from adm_ai_rag_collections)
union all select 'uc_ai agents',        count(*) from uc_ai_agents where code like 'aic\_%' escape '\'
union all select 'uc_ai profiles',      count(*) from uc_ai_prompt_profiles where code like 'AIC\_%' escape '\'
union all select 'uc_ai tools',         count(*) from uc_ai_tools where code like 'AIC\_%' escape '\'
union all select 'uc_ai executions',    count(*) from uc_ai_agent_executions where created_by like 'AIC\_%' escape '\'
union all select 'uc_ai memory stores', count(*) from uc_ai_memory_stores where username like 'AIC\_%' escape '\'
union all select 'aic objects',         count(*) from user_objects where object_name like 'AIC\_%' escape '\';
set feedback on
