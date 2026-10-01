-- Removes everything the "Build workflows on hooks" tutorial created and gives the hook slots back.
-- Run in SQLcl or SQL*Plus, connected as the ADM schema owner.
--
--   @99_teardown.sql
--
-- What it deletes: the hkd_ packages, tables, the queue and its type, the scheduler job, the AQ
-- notification registration, and the hook snippets that start with hkd_hook_api. It moves the folder
-- hkd_tutorial, with every document and folder the lessons created in it, to the trash of the ADM user.
-- It does not touch other hooks. Documents the workflows tagged outside that folder keep their tags.
--
-- The same script also removes the finished sample app (examples/hooks-demo-app), which uses the same
-- hkd_ names.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback on

prompt === hooks ===
update adm_hooks
   set hook_plsql = null
 where hook_plsql like 'hkd_hook_api.%';

prompt === job and notification ===
begin
  for r in (select job_name from user_scheduler_jobs where job_name = 'HKD_PROCESS_QUEUE_JOB') loop
    sys.dbms_scheduler.drop_job(r.job_name, force => true);
  end loop;

  for r in (select location_name from user_subscr_registrations where location_name like '%HKD_WORKER_API.ON_MESSAGE%') loop
    sys.dbms_aq.unregister(
      reg_list => sys.aq$_reg_info_list(
                    sys.aq$_reg_info(
                      user || '.HKD_EVENT_Q'
                    , sys.dbms_aq.namespace_aq
                    , r.location_name
                    , hextoraw('FF')
                    )
                  )
    , reg_count => 1
    );
  end loop;
end;
/

prompt === queue ===
declare
  l_exists number;
begin
  select count(*) into l_exists from user_queue_tables where queue_table = 'HKD_EVENT_QT';
  if l_exists > 0 then
    sys.dbms_aqadm.drop_queue_table(queue_table => 'HKD_EVENT_QT', force => true);
  end if;
end;
/

prompt === packages, type and tables ===
declare
  procedure drop_if_exists (
    p_type in varchar2
  , p_name in varchar2
  , p_tail in varchar2 default null
  )
  as
    l_exists number;
  begin
    select count(*)
      into l_exists
      from user_objects
     where object_type = p_type
       and object_name = upper(p_name);

    if l_exists > 0 then
      execute immediate 'drop ' || lower(p_type) || ' ' || p_name || ' ' || p_tail;
    end if;
  end drop_if_exists;
begin
  drop_if_exists('PACKAGE', 'hkd_demo_api');
  drop_if_exists('PACKAGE', 'hkd_worker_api');
  drop_if_exists('PACKAGE', 'hkd_hook_api');
  drop_if_exists('FUNCTION', 'hkd_visible_messages');
  drop_if_exists('TYPE', 'hkd_event_t');
  drop_if_exists('TABLE', 'hkd_notifications', 'purge');
  drop_if_exists('TABLE', 'hkd_workflow_runs', 'purge');
  drop_if_exists('TABLE', 'hkd_rejections', 'purge');
  drop_if_exists('TABLE', 'hkd_blocked_extensions', 'purge');
  drop_if_exists('TABLE', 'hkd_workflows', 'purge');
end;
/

prompt === working folder ===
declare
begin
  adm_context_api.system_user_login('&hkd_user');

  for r in (
    select folder_id
      from adm_folders
     where folder_name  = 'hkd_tutorial'
       and folder_path  = '/users/' || lower('&hkd_user') || '/hkd_tutorial'
       and deleted_flag = 'N'
  ) loop
    adm_folder_api.trash_folder(r.folder_id, '&hkd_user');
  end loop;

  commit;
end;
/

prompt
prompt teardown OK
