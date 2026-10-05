-- Installs the database side of the "Classify uploads with an LLM" course. Run as the ADM
-- schema owner, from this folder:
--
--   sql -name local-23ai-adm @install.sql
--
-- Needs the finished hooks demo (../db/install.sql) and the AI Pack with a working OpenAI
-- web credential. 00_precheck.sql checks both. Re-runnable.

set define off
whenever sqlerror exit failure

prompt === tables and view ===
@@01_hkd_ai_tables.sql

prompt === hkd_ai_api ===
@@02_hkd_ai_api.pks
@@02_hkd_ai_api.pkb

prompt === register workflows ===
@@03_hkd_ai_register.sql

set define on
whenever sqlerror continue

prompt === invalid objects ===
select object_name
     , object_type
     , status
  from user_objects
 where status != 'VALID'
   and object_name like 'HKD%';

prompt done.
