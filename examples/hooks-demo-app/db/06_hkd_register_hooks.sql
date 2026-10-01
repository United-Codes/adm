-- Wires everything together:
--   1. registers the three ADM hooks (adm_hooks.hook_plsql)
--   2. registers the AQ notification that wakes the worker
--   3. creates the scheduler job that sweeps the queue as a safety net
--
-- Re-runnable. It refuses to overwrite a hook somebody else registered: ADM allows exactly
-- one snippet per event, so claiming a slot that is already taken would silently break
-- whatever relied on it. Run 99_hkd_uninstall.sql to give the slots back.

declare
  c_updated_by constant adm_hooks.updated_by%type := 'HKD_DEMO';

  procedure register_hook (
    p_hook_key in adm_hooks.hook_key%type
  , p_plsql    in adm_hooks.hook_plsql%type
  )
  as
    l_current adm_hooks.hook_plsql%type;
  begin
    select hook_plsql
      into l_current
      from adm_hooks
     where hook_key = p_hook_key;

    if l_current is not null and l_current not like 'hkd_hook_api.%' then
      raise_application_error(
        -20700
      , p_hook_key || ' already runs somebody else''s code. Not overwriting it:' || chr(10) || l_current
      );
    end if;

    update adm_hooks
       set hook_plsql   = p_plsql
         , updated_by   = c_updated_by
         , updated_date = current_timestamp
     where hook_key = p_hook_key;
  end register_hook;
begin
  register_hook(
    'AFTER_NEW_FILE_UPLOAD'
  , 'hkd_hook_api.after_new_file_upload(p_document_id => :p_document_id, p_version_id => :p_version_id);'
  );
  register_hook(
    'AFTER_NEW_FILE_VERSION'
  , 'hkd_hook_api.after_new_file_version(p_document_id => :p_document_id, p_version_id => :p_version_id);'
  );
  register_hook(
    'AFTER_NEW_FOLDER_CREATION'
  , 'hkd_hook_api.after_new_folder_creation(p_folder_id => :p_folder_id);'
  );
end;
/

-- The notification. Oracle calls hkd_worker_api.on_message in a job session as soon as a
-- message becomes visible, i.e. when the uploader's transaction commits.
declare
  l_exists number;
begin
  select count(*)
    into l_exists
    from user_subscr_registrations
   where location_name like '%HKD_WORKER_API.ON_MESSAGE%';

  if l_exists = 0 then
    sys.dbms_aq.register(
      reg_list => sys.aq$_reg_info_list(
                    sys.aq$_reg_info(
                      user || '.HKD_EVENT_Q'
                    , sys.dbms_aq.namespace_aq
                    , 'plsql://' || user || '.HKD_WORKER_API.ON_MESSAGE'
                    , hextoraw('FF')
                    )
                  )
    , reg_count => 1
    );
  end if;
exception
  when others then
    -- Some databases cannot run a notification callback (no job processes, a managed service). The
    -- scheduler job below still processes every message, only later.
    dbms_output.put_line('The notification was not registered: ' || sqlerrm);
    dbms_output.put_line('The scheduler job will process the messages.');
end;
/

-- The sweeper. A message that failed waits out its retry delay without anything announcing
-- that it is ready again, so something has to look. The job repeats every 30 seconds. The
-- scheduler can start a run later than that.
declare
  l_exists number;
begin
  select count(*)
    into l_exists
    from user_scheduler_jobs
   where job_name = 'HKD_PROCESS_QUEUE_JOB';

  if l_exists = 0 then
    sys.dbms_scheduler.create_job(
      job_name        => 'HKD_PROCESS_QUEUE_JOB'
    , job_type        => 'STORED_PROCEDURE'
    , job_action      => 'HKD_WORKER_API.PROCESS_QUEUE'
    , repeat_interval => 'FREQ=SECONDLY;INTERVAL=30'
    , enabled         => true
    , comments        => 'Hooks demo: sweeps the event queue for retried messages'
    );
  end if;
end;
/
