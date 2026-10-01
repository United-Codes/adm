-- Installs the database side of the "Hooks Demo" app. Run as the ADM schema owner:
--
--   sql -name local-23ai-adm @examples/hooks-demo-app/db/install.sql
--
-- Needs 00_dba_grants.sql to have been run once by a DBA (Advanced Queuing privileges).
-- Re-runnable.

set define off
whenever sqlerror exit failure

prompt === tables ===
@@01_hkd_tables.sql

prompt === queue ===
@@02_hkd_queue.sql

prompt === hkd_hook_api ===
@@03_hkd_hook_api.pks
@@03_hkd_hook_api.pkb

prompt === hkd_worker_api ===
@@04_hkd_worker_api.pks
@@04_hkd_worker_api.pkb

prompt === hkd_demo_api ===
@@05_hkd_demo_api.pks
@@05_hkd_demo_api.pkb

prompt === register hooks, notification and job ===
@@06_hkd_register_hooks.sql

commit;

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
