create or replace package body hkd_hook_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_hook_api.';

  -- Customer code raises in -20700 .. -20999, the range ADM keeps free for it. ADM does not wrap an
  -- error from that range: the caller gets this number and this message, and the APEX error handler
  -- shows the message to the user. So the message is written for the user.
  c_err_blocked_extension constant number := -20701;
  c_err_empty_file        constant number := -20702;
  c_err_generation_limit  constant number := -20703;

  -- A chain of events: a workflow's work starts an event, whose workflow starts the next one.
  -- Real chains are two or three long. Six in a row is a loop.
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


  procedure after_new_file_version (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
  begin
    guard_file(adm_hooks_api.c_after_new_file_version, p_document_id, p_version_id);
    enqueue_event(adm_hooks_api.c_after_new_file_version, p_document_id, p_version_id);
  end after_new_file_version;


  procedure after_new_folder_creation (
    p_folder_id in adm_folders.folder_id%type
  )
  as
  begin
    enqueue_event(adm_hooks_api.c_after_new_folder_creation, p_folder_id => p_folder_id);
  end after_new_folder_creation;

end hkd_hook_api;
/
