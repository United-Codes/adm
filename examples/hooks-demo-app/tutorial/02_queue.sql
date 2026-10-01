-- Lesson 2: hand the work to a queue. Run in SQLcl or SQL*Plus, connected as the ADM schema owner,
-- after 01_guard.sql.
--
--   @02_queue.sql
--
-- What it does:
--   1. creates the payload type hkd_event_t, the queue table, the queue HKD_EVENT_Q and opens its
--      exception queue (needs execute on dbms_aqadm)
--   2. creates hkd_visible_messages, a helper that counts the messages other sessions can see
--   3. replaces hkd_hook_api: the hook now guards the file and then puts one message on the queue
--
-- Re-runnable. The hook registration from lesson 1 does not change.

set verify off
set serveroutput on
whenever sqlerror exit failure

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
      , generation  number
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

-- How many messages could another session read right now? The function runs in an autonomous
-- transaction, so it sees only what has been committed. Use it to check that the queue holds a message
-- back until the uploader commits.
create or replace function hkd_visible_messages return number
as
  pragma autonomous_transaction;
  l_count number;
begin
  select count(*)
    into l_count
    from aq$hkd_event_qt
   where queue     = 'HKD_EVENT_Q'
     and msg_state = 'READY';

  return l_count;
end hkd_visible_messages;
/

create or replace package hkd_hook_api as

  -- Tells the hook the generation of the event the worker is handling, 0 outside the worker.
  procedure set_generation (
    p_generation in number
  );

  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  );

end hkd_hook_api;
/

create or replace package body hkd_hook_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_hook_api.';

  -- Errors raised by customer code use -20700 .. -20999. ADM never uses that range.
  c_err_blocked_extension constant number := -20701;
  c_err_empty_file        constant number := -20702;
  c_err_generation_limit  constant number := -20703;
  c_max_generation        constant number := 5;

  g_generation            number := 0;

  procedure set_generation (
    p_generation in number
  )
  as
  begin
    g_generation := p_generation;
  end set_generation;


  /**
   * Keeps a record of a refusal. The user already reads the reason in the error itself, but a
   * refused upload leaves nothing behind in ADM, so this table is the only place an
   * administrator can see what was refused, for whom, and why. AUTONOMOUS, and that is the whole
   * point: the hook refuses by raising, the raise rolls the upload back, and an ordinary insert
   * would be rolled back with it. The pragma commits only this one row and leaves the caller's
   * transaction alone - the one situation where a hook may commit anything at all.
   */
  procedure log_rejection (
    p_hook_key in varchar2
  , p_subject  in varchar2
  , p_reason   in varchar2
  )
  as
    pragma autonomous_transaction;
  begin
    insert into hkd_rejections (hook_key, subject, reason, rejected_by)
    values (p_hook_key, substr(p_subject, 1, 1000), substr(p_reason, 1, 1000), sys_context('ADM_CONTEXT', 'ADM_USERNAME'));

    commit;
  end log_rejection;


  /**
   * Refuses the file when a rule says so, with a message for the user. Reads metadata only - never the file content, which
   * may live in object storage and cost a network round trip on the upload path.
   */
  procedure guard_file (
    p_hook_key    in varchar2
  , p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
    l_name      adm_documents.document_name%type;
    l_file_size adm_document_versions.file_size%type;
    l_extension varchar2(20 char);
    l_reason    hkd_blocked_extensions.reason%type;
    l_message   varchar2(1000 char);
  begin
    select d.document_name
         , v.file_size
      into l_name
         , l_file_size
      from adm_documents d
      join adm_document_versions v
        on v.document_id = d.document_id
     where d.document_id = p_document_id
       and v.version_id  = p_version_id;

    if instr(l_name, '.') > 0 then
      l_extension := lower(regexp_substr(l_name, '[^.]+$'));

      begin
        select reason
          into l_reason
          from hkd_blocked_extensions
         where extension = l_extension;

        l_message := 'Files of type .' || l_extension || ' are not accepted: ' || l_reason;
        log_rejection(p_hook_key, l_name, l_message);
        raise_application_error(c_err_blocked_extension, l_message);
      exception
        when no_data_found then
          null;
      end;
    end if;

    if nvl(l_file_size, 0) = 0 then
      l_message := 'The file is empty (0 bytes), there is nothing to store';
      log_rejection(p_hook_key, l_name, l_message);
      raise_application_error(c_err_empty_file, l_message);
    end if;
  end guard_file;


  /**
   * Puts one event on the queue. The default visibility is ON_COMMIT: the message becomes
   * visible to the worker when the upload commits, and disappears with it on a rollback.
   * That is what makes the queue safe where a "fire and forget" job started from the hook
   * would not be - that job would run for a file that never got committed.
   */
  procedure enqueue_event (
    p_hook_key    in varchar2
  , p_document_id in number default null
  , p_version_id  in number default null
  , p_folder_id   in number default null
  )
  as
    l_enqueue_options    sys.dbms_aq.enqueue_options_t;
    l_message_properties sys.dbms_aq.message_properties_t;
    l_msg_id             raw(16);
    l_generation         number := g_generation + 1;
  begin
    -- Raising here fails the work that started the chain: the worker rolls that message back,
    -- the failure shows in hkd_workflow_runs and the message ends in the exception queue.
    if l_generation > c_max_generation then
      raise_application_error(
        c_err_generation_limit
      , 'More than ' || c_max_generation || ' events in a row started each other. A workflow probably feeds itself.'
      );
    end if;

    sys.dbms_aq.enqueue(
      queue_name         => 'HKD_EVENT_Q'
    , enqueue_options    => l_enqueue_options
    , message_properties => l_message_properties
    , payload            => hkd_event_t(
                              p_hook_key
                            , p_document_id
                            , p_version_id
                            , p_folder_id
                            , sys_context('ADM_CONTEXT', 'ADM_USERNAME')
                            , l_generation
                            )
    , msgid              => l_msg_id
    );

    apex_debug.info('%s queued event %s as %s', c_scope_prefix, p_hook_key, rawtohex(l_msg_id));
  end enqueue_event;


  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
  begin
    guard_file(adm_hooks_api.c_after_new_file_upload, p_document_id, p_version_id);
    enqueue_event(adm_hooks_api.c_after_new_file_upload, p_document_id, p_version_id);
  end after_new_file_upload;

end hkd_hook_api;
/

show errors

whenever sqlerror continue
