-- Installs the database side of the "Ask questions across your documents" course, up to the first
-- agent with one tool. Run as the ADM schema owner, from this folder:
--
--   sql -name local-23ai-adm @install.sql
--
-- Needs the AI Pack with a working OpenAI web credential named OPENAI, on Oracle 23ai or later.
-- 00_precheck.sql checks that. Re-runnable: data that exists is left alone, packages and
-- registrations are replaced. 99_aic_teardown.sql removes all of it again.
--
-- Embeds about 3,000 tokens and reads one scanned page with a model (step 3b): fractions of a cent.
-- Every upload passes p_run_hooks => false, so no ADM hook runs on the sample files.
--
-- The lesson scripts (05, 09 to 16) are not part of the install. Run them one by one.

set define off
whenever sqlerror exit failure

prompt === 1/7 users and groups ===
@@01_aic_users.sql
prompt === 2/7 sample files, folders and shares ===
@@02_aic_load_pdfs.sql
prompt === 3/7 RAG collections ===
@@03_aic_collections.sql
prompt === 4/7 index: text index, user caches, embeddings ===
@@04_aic_index.sql
prompt === 5/7 the search tools ===
@@06_aic_rag_tools_api.pks
@@06_aic_rag_tools_api.pkb
prompt === 6/7 the demo helper that runs an agent as a user ===
@@07_aic_agent_api.pks
@@07_aic_agent_api.pkb
prompt === 7/7 tool, prompt profile and agent ===
@@08_aic_register.sql

set define off
whenever sqlerror continue
set linesize 200
col what   format a28
col detail format a100

prompt
prompt === verification ===
select 'invalid aic objects' as what, to_char(count(*)) as detail from user_objects where object_name like 'AIC\_%' escape '\' and status != 'VALID'
union all
select 'users', listagg(u.username || ' (' || r.role_name || ')', ', ') within group (order by u.username)
  from adm_users u join adm_roles r on r.role_id = u.role_id where u.username like 'AIC\_%' escape '\'
union all
select 'files indexed', collection_name || ': ' || sum(case when file_status = 'INDEXED' then 1 else 0 end) || ' of ' || count(*)
  from adm_ai_rag_collection_files_v where collection_name like 'aic\_%' escape '\' and is_active = 'Y' group by collection_name
union all
select 'agent', code || ', ' || status || ', profile ' || prompt_profile_code from uc_ai_agents where code = 'aic_assistant'
union all
select 'tools', listagg(code, ', ') within group (order by code) from uc_ai_tools where code like 'AIC\_%' escape '\';

prompt
prompt Next: sql -name <connection> @05_aic_lesson1_answers.sql
