-- Lesson 6: the folder blueprint with its guard. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after 06_blueprint_loop.sql (or straight after 05_wake.sql).
--
--   @06_blueprint.sql
--
-- What it does: installs the finished demo (examples/hooks-demo-app/db) over everything the lessons
-- built. Same object names, so the lessons' packages are replaced, the missing tables are created and
-- the missing hooks are registered. The folder blueprint now only applies to a folder directly
-- inside a folder named Projects. The worker job and the notification are enabled again.
--
-- It does NOT create the APEX application: see the Hooks demo app page for that.

@@../db/install.sql

begin
  for r in (select job_name from user_scheduler_jobs where job_name = 'HKD_PROCESS_QUEUE_JOB') loop
    sys.dbms_scheduler.enable(r.job_name);
  end loop;
end;
/
