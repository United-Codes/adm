-- The Advanced Queuing side. Needs execute on dbms_aqadm / dbms_aq - see 00_dba_grants.sql.
--
-- The hook never does the work. It drops a small message into this queue and returns, so the
-- upload is exactly as fast as without a hook. A worker picks the message up afterwards in a
-- transaction of its own: if the worker fails, the upload is not affected, and the queue
-- redelivers the message.
--
-- Why a queue rather than a plain table the worker polls:
--   - the enqueue is part of the uploader's transaction: roll the upload back and the message
--     goes with it, so the worker never sees an event for a file that does not exist
--   - dequeue locks the message, so several workers can run side by side without
--     double-processing anything
--   - retries, a delay between them and an exception queue for messages that keep failing
--     are built in
--
-- Re-runnable: whatever exists is left alone.

-- Not "create or replace": once the queue table exists it depends on the type and Oracle
-- refuses to replace it (ORA-02303), which would make this script fail on every second run.
declare
  l_exists number;
begin
  select count(*)
    into l_exists
    from user_types
   where type_name = 'HKD_EVENT_T';

  if l_exists = 0 then
    execute immediate q'[
      create type hkd_event_t as object (
        hook_key    varchar2(255 char)
      , document_id number
      , version_id  number
      , folder_id   number
      , actor       varchar2(255 char)
      )
    ]';
  end if;
end;
/

declare
  l_exists number;
begin
  select count(*)
    into l_exists
    from user_queue_tables
   where queue_table = 'HKD_EVENT_QT';

  if l_exists = 0 then
    sys.dbms_aqadm.create_queue_table(
      queue_table        => 'HKD_EVENT_QT'
    , queue_payload_type => 'HKD_EVENT_T'
    , multiple_consumers => false
    , comment            => 'ADM hook events waiting for the Hooks Demo worker'
    );
  end if;

  select count(*)
    into l_exists
    from user_queues
   where name = 'HKD_EVENT_Q';

  if l_exists = 0 then
    sys.dbms_aqadm.create_queue(
      queue_name     => 'HKD_EVENT_Q'
    , queue_table    => 'HKD_EVENT_QT'
      -- a failed delivery is retried 3 times, 5 seconds apart, then the message moves to
      -- the exception queue AQ$_HKD_EVENT_QT_E instead of being retried forever
    , max_retries    => 3
    , retry_delay    => 5
      -- keep consumed messages for a day so the app can show what was processed. A
      -- production queue would normally keep them far shorter or not at all.
    , retention_time => 86400
    , comment        => 'ADM hook events'
    );
  end if;

  -- start_queue is idempotent for an already started queue
  sys.dbms_aqadm.start_queue(queue_name => 'HKD_EVENT_Q');

  -- Oracle creates the exception queue next to the main one, but leaves it closed for dequeue.
  -- Open it so a message that ran out of retries can be taken out and tried again
  -- (hkd_worker_api.requeue_failed). Nothing may enqueue into it by hand.
  sys.dbms_aqadm.start_queue(queue_name => 'AQ$_HKD_EVENT_QT_E', enqueue => false, dequeue => true);
end;
/
