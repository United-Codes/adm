-- Removes the Hooks Demo from the schema and gives the hook slots back. Does not touch the
-- documents, folders and tags the workflows created in ADM - those are real ADM data.
--
--   sql -name local-23ai-adm @examples/hooks-demo-app/db/99_hkd_uninstall.sql

set define off

-- 1. stop reacting to events
update adm_hooks
   set hook_plsql = null
 where hook_plsql like 'hkd_hook_api.%';

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

-- 2. the queue (force drops the messages too)
declare
  l_exists number;
begin
  select count(*) into l_exists from user_queue_tables where queue_table = 'HKD_EVENT_QT';
  if l_exists > 0 then
    sys.dbms_aqadm.drop_queue_table(queue_table => 'HKD_EVENT_QT', force => true);
  end if;
end;
/

-- 3. code and tables (whatever exists: the tutorial installs a part of this)
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
