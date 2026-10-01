-- One-time setup, run as a DBA (SYS / SYSTEM in the PDB) - everything else in this
-- demo runs as the ADM schema owner:
--
--   sql -name local-23ai-sys @examples/hooks-demo-app/db/00_dba_grants.sql ADM
--
-- &1 = the schema that owns ADM. Advanced Queuing is the only thing the demo needs
-- that a plain developer schema does not already have: DBMS_AQADM to create the queue
-- and DBMS_AQ to enqueue and dequeue.

grant execute on sys.dbms_aqadm to &1;
grant execute on sys.dbms_aq    to &1;
