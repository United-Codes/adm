create or replace package body hkd_worker_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_worker_api.';
  c_queue        constant varchar2(30 char) := 'HKD_EVENT_Q';
  c_exception_q  constant varchar2(30 char) := 'AQ$_HKD_EVENT_QT_E';

  c_large_file_bytes constant number := 10 * 1024 * 1024;

  -- Customer range -20700 .. -20999
  c_err_simulated_failure constant number := -20720;

  e_no_messages exception;
  pragma exception_init(e_no_messages, -25228);

  -- What a workflow reports back. The worker turns it into a hkd_workflow_runs row.
  type t_outcome is record (
    status  hkd_workflow_runs.status%type
  , summary hkd_workflow_runs.summary%type
  );

  -- What the worker knows about the message it is working on.
  type t_delivery is record (
    msg_id      raw(16)
  , attempt     number
  , enqueued_at timestamp with local time zone
  );


  function outcome (
    p_status  in varchar2
  , p_summary in varchar2
  ) return t_outcome
  as
    l_outcome t_outcome;
  begin
    l_outcome.status  := p_status;
    l_outcome.summary := substr(p_summary, 1, 1000);
    return l_outcome;
  end outcome;


  function format_size (
    p_bytes in number
  ) return varchar2
  as
  begin
    return case
             when p_bytes is null then 'unknown size'
             when p_bytes < 1024 then p_bytes || ' B'
             when p_bytes < 1024 * 1024 then round(p_bytes / 1024, 1) || ' KB'
             else round(p_bytes / 1024 / 1024, 1) || ' MB'
           end;
  end format_size;


  -- ADM ships with CONTRIBUTOR / VIEWER role names; the worker acts as the system user for
  -- everything that is not "on behalf of someone", so the audit log says an automation did it.
  procedure act_as_system
  as
  begin
    adm_context_api.system_login;
  end act_as_system;


  -----------------------------------------------------------------------------------------
  -- Workflow 1: intake classification (AFTER_NEW_FILE_UPLOAD)
  -----------------------------------------------------------------------------------------
  function classify_document (
    p_name in varchar2
  , p_mime in varchar2
  ) return varchar2
  as
    l_name varchar2(1000 char) := lower(p_name);
  begin
    return case
             when regexp_like(l_name, '^(inv|invoice|rechnung)[-_ 0-9]') then 'invoice'
             when regexp_like(l_name, 'contract|agreement|nda|vertrag') then 'contract'
             when p_mime like 'image/%' then 'image'
             when regexp_like(l_name, '\.(xlsx?|csv|ods)$') or p_mime like '%spreadsheet%' then 'spreadsheet'
             when regexp_like(l_name, '\.(pptx?|odp)$') or p_mime like '%presentation%' then 'presentation'
             when regexp_like(l_name, '\.(docx?|pdf|txt|md|odt|rtf)$') or p_mime like 'text/%' then 'document'
             else 'other'
           end;
  end classify_document;


  function wf_intake_classify (
    p_event in hkd_event_t
  ) return t_outcome
  as
    l_name     adm_documents.document_name%type;
    l_mime     adm_documents.file_mime_type%type;
    l_category varchar2(30 char);
    l_tags     varchar2(200 char);
  begin
    begin
      select document_name
           , file_mime_type
        into l_name
           , l_mime
        from adm_documents
       where document_id = p_event.document_id
         and deleted_flag = 'N';
    exception
      when no_data_found then
        -- The message is only a pointer. By the time the worker runs, the document can be gone.
        return outcome('SKIPPED', 'The document no longer exists');
    end;

    -- A deliberate failure so the demo can show the retry and exception queue behaviour:
    -- name a file "...poison..." and this workflow raises on every attempt.
    if lower(l_name) like '%poison%' then
      raise_application_error(c_err_simulated_failure, 'Simulated workflow failure for "' || l_name || '"');
    end if;

    l_category := classify_document(l_name, l_mime);
    adm_tag_api.add_tag_to_document(p_event.document_id, 'category', l_category);
    l_tags := 'category=' || l_category;

    if l_category in ('invoice', 'contract') then
      adm_tag_api.add_tag_to_document(p_event.document_id, 'needs-review');
      l_tags := l_tags || ', needs-review';
    end if;

    return outcome('OK', 'Classified as ' || l_category || ', tagged ' || l_tags);
  end wf_intake_classify;


  -----------------------------------------------------------------------------------------
  -- Workflow 2: duplicate and integrity scan (AFTER_NEW_FILE_UPLOAD)
  -----------------------------------------------------------------------------------------
  function wf_duplicate_scan (
    p_event in hkd_event_t
  ) return t_outcome
  as
    l_checksum   adm_document_versions.checksum%type;
    l_file_size  adm_document_versions.file_size%type;
    l_other_name adm_documents.document_name%type;
    l_flags      varchar2(1000 char);
  begin
    begin
      select v.checksum
           , v.file_size
        into l_checksum
           , l_file_size
        from adm_document_versions v
        join adm_documents d
          on d.document_id = v.document_id
       where v.version_id   = p_event.version_id
         and d.deleted_flag = 'N';
    exception
      when no_data_found then
        -- The message is only a pointer. The document can be in the trash by now, or a save inside
        -- the merge window can have replaced the version it points at.
        return outcome('SKIPPED', 'The document or version no longer exists');
    end;

    -- the checksum is computed by ADM when the version is stored, so this never reads the file
    begin
      select d.document_name
        into l_other_name
        from adm_documents d
        join adm_document_versions v
          on v.version_id = d.latest_version_id
       where v.checksum       = l_checksum
         and d.document_id   != p_event.document_id
         and d.deleted_flag   = 'N'
       order by d.created_date
       fetch first 1 row only;

      adm_tag_api.add_tag_to_document(p_event.document_id, 'duplicate-of', l_other_name);
      l_flags := 'identical to "' || l_other_name || '"';
    exception
      when no_data_found then
        null;
    end;

    if l_file_size > c_large_file_bytes then
      adm_tag_api.add_tag_to_document(p_event.document_id, 'large-file', format_size(l_file_size));
      l_flags := l_flags || case when l_flags is not null then '; ' end
                         || 'large file (' || format_size(l_file_size) || ')';
    end if;

    if l_flags is null then
      return outcome('OK', 'Unique content, ' || format_size(l_file_size));
    end if;

    return outcome('FLAGGED', upper(substr(l_flags, 1, 1)) || substr(l_flags, 2));
  end wf_duplicate_scan;


  -----------------------------------------------------------------------------------------
  -- Workflow 3: version change digest (AFTER_NEW_FILE_VERSION)
  -----------------------------------------------------------------------------------------
  function wf_version_digest (
    p_event in hkd_event_t
  ) return t_outcome
  as
    l_name         adm_documents.document_name%type;
    l_owner        varchar2(255 char);
    l_number       adm_document_versions.version_number%type;
    l_size         adm_document_versions.file_size%type;
    l_prev_number  adm_document_versions.version_number%type;
    l_prev_size    adm_document_versions.file_size%type;
    l_change       varchar2(500 char);
    l_status       varchar2(10 char) := 'OK';
  begin
    begin
      select d.document_name
           , coalesce(d.user_owner, d.created_by)
           , v.version_number
           , v.file_size
        into l_name
           , l_owner
           , l_number
           , l_size
        from adm_documents d
        join adm_document_versions v
          on v.document_id = d.document_id
       where d.document_id = p_event.document_id
         and v.version_id  = p_event.version_id;
    exception
      when no_data_found then
        return outcome('SKIPPED', 'The version no longer exists: a later save replaced it');
    end;

    begin
      select version_number
           , file_size
        into l_prev_number
           , l_prev_size
        from adm_document_versions
       where document_id     = p_event.document_id
         and version_number  < l_number
       order by version_number desc
       fetch first 1 row only;
    exception
      when no_data_found then
        return outcome('SKIPPED', 'No earlier version to compare with');
    end;

    l_change := 'size ' || format_size(l_prev_size) || ' -> ' || format_size(l_size);

    if l_prev_size > 0 then
      l_change := l_change || ' (' || to_char(round((l_size - l_prev_size) / l_prev_size * 100), 'FMS9990') || '%)';

      -- A version that lost more than half of its predecessor is worth a second look: a
      -- truncated upload, or the wrong file saved over the right one.
      if l_size < l_prev_size / 2 then
        l_status := 'FLAGGED';
        l_change := l_change || ' - shrank by more than half';
      end if;
    end if;

    insert into hkd_notifications (document_id, recipient, subject, body)
    values (
      p_event.document_id
    , l_owner
    , 'Version ' || l_number || ' of "' || l_name || '"'
    , p_event.actor || ' saved version ' || l_number || ' of "' || l_name || '": ' || l_change || '.'
    );

    return outcome(l_status, 'Version ' || l_number || ': ' || l_change || '. Notified ' || l_owner);
  end wf_version_digest;


  -----------------------------------------------------------------------------------------
  -- Workflow 4: project folder blueprint (AFTER_NEW_FOLDER_CREATION)
  -----------------------------------------------------------------------------------------
  function wf_folder_blueprint (
    p_event in hkd_event_t
  ) return t_outcome
  as
    type t_names is table of varchar2(100 char);
    c_blueprint constant t_names := t_names('01_Contracts', '02_Deliverables', '03_Archive');

    l_folder_name   adm_folders.folder_name%type;
    l_parent_id     adm_folders.parent_folder_id%type;
    l_parent_name   adm_folders.folder_name%type;
    l_exists        number;
    l_created       number := 0;
  begin
    begin
      select f.folder_name
           , f.parent_folder_id
           , p.folder_name
        into l_folder_name
           , l_parent_id
           , l_parent_name
        from adm_folders f
        left join adm_folders p
          on p.folder_id = f.parent_folder_id
       where f.folder_id = p_event.folder_id
         and f.deleted_flag = 'N';
    exception
      when no_data_found then
        return outcome('SKIPPED', 'The folder no longer exists');
    end;

    -- The recursion guard. The sub folders created below fire this very hook again; they sit
    -- inside the project folder, not inside "Projects", so they fall out here. Without a guard
    -- like this the workflow would feed itself.
    if lower(l_parent_name) is null or lower(l_parent_name) != 'projects' then
      return outcome('SKIPPED', 'Not directly inside a folder named Projects');
    end if;

    -- Create the sub folders as the person who created the project folder, so they own them
    -- and can work in them. The system user would work too, but the owner would be wrong.
    if p_event.actor is null or p_event.actor = adm_context_api.c_system_user then
      adm_context_api.system_login;
    else
      adm_context_api.system_user_login(p_event.actor);
    end if;

    for i in 1 .. c_blueprint.count loop
      select count(*)
        into l_exists
        from adm_folders
       where parent_folder_id = p_event.folder_id
         and folder_name      = c_blueprint(i)
         and deleted_flag     = 'N';

      if l_exists = 0 then
        adm_folder_api.add_folder(
          p_folder_name      => c_blueprint(i)
        , p_parent_folder_id => p_event.folder_id
        );
        l_created := l_created + 1;
      end if;
    end loop;

    return outcome('OK', 'Project "' || l_folder_name || '": created ' || l_created || ' of '
                         || c_blueprint.count || ' standard sub folders');
  end wf_folder_blueprint;


  -----------------------------------------------------------------------------------------
  -- Dispatch
  -----------------------------------------------------------------------------------------
  procedure record_run (
    p_event    in hkd_event_t
  , p_delivery in t_delivery
  , p_workflow in hkd_workflows.workflow_code%type
  , p_outcome  in t_outcome
  )
  as
    l_subject hkd_workflow_runs.subject%type;
  begin
    if p_event.document_id is not null then
      select min(document_name) into l_subject from adm_documents where document_id = p_event.document_id;
    else
      select min(folder_name) into l_subject from adm_folders where folder_id = p_event.folder_id;
    end if;

    insert into hkd_workflow_runs (
      msg_id, hook_key, workflow_code, document_id, version_id, folder_id
    , subject, status, summary, actor, enqueued_at, attempt
    ) values (
      p_delivery.msg_id, p_event.hook_key, p_workflow, p_event.document_id, p_event.version_id, p_event.folder_id
    , l_subject, p_outcome.status, p_outcome.summary, p_event.actor, p_delivery.enqueued_at, p_delivery.attempt
    );
  end record_run;


  /**
   * Runs every enabled workflow registered for the event's hook. An exception from a
   * workflow propagates: the caller rolls the whole message back, so either all workflows
   * of a message are recorded or none are.
   */
  procedure process_event (
    p_event    in hkd_event_t
  , p_delivery in t_delivery
  )
  as
    l_outcome t_outcome;
  begin
    for r_wf in (
      select workflow_code
        from hkd_workflows
       where hook_key     = p_event.hook_key
         and enabled_flag = 'Y'
       order by sort_order
    ) loop
      act_as_system;

      l_outcome := case r_wf.workflow_code
                     when 'INTAKE_CLASSIFY'  then wf_intake_classify(p_event)
                     when 'DUPLICATE_SCAN'   then wf_duplicate_scan(p_event)
                     when 'VERSION_DIGEST'   then wf_version_digest(p_event)
                     when 'FOLDER_BLUEPRINT' then wf_folder_blueprint(p_event)
                   end;

      record_run(p_event, p_delivery, r_wf.workflow_code, l_outcome);
    end loop;
  end process_event;


  /**
   * Records that a delivery failed. AUTONOMOUS because the caller has just rolled back to put
   * the message back on the queue, and this row has to survive that.
   */
  procedure record_failure (
    p_event    in hkd_event_t
  , p_delivery in t_delivery
  , p_error    in varchar2
  )
  as
    pragma autonomous_transaction;
  begin
    insert into hkd_workflow_runs (
      msg_id, hook_key, workflow_code, document_id, version_id, folder_id
    , subject, status, summary, actor, enqueued_at, attempt
    ) values (
      p_delivery.msg_id, p_event.hook_key, 'WORKER', p_event.document_id, p_event.version_id, p_event.folder_id
    , null, 'FAILED', substr(p_error, 1, 1000), p_event.actor, p_delivery.enqueued_at, p_delivery.attempt
    );

    commit;
  end record_failure;


  function process_queue (
    p_max_messages in number default null
  ) return number
  as
    l_dequeue_options    sys.dbms_aq.dequeue_options_t;
    l_message_properties sys.dbms_aq.message_properties_t;
    l_event              hkd_event_t;
    l_delivery           t_delivery;
    l_handled            number := 0;
    l_tried              number := 0;
    l_user               varchar2(255 char) := sys_context('ADM_CONTEXT', 'ADM_USERNAME');
    l_role               varchar2(30 char)  := sys_context('ADM_CONTEXT', 'ADM_ROLE');
    l_source             varchar2(30 char)  := sys_context('ADM_CONTEXT', 'ADM_ACCESS_SOURCE');
  begin
    -- no_wait: return at once when nothing is ready. A scheduler job should not sit on a
    -- dequeue; the notification wakes us up when there is something to do.
    l_dequeue_options.wait       := sys.dbms_aq.no_wait;
    l_dequeue_options.navigation := sys.dbms_aq.first_message;

    <<message_loop>>
    loop
      exit message_loop when p_max_messages is not null and l_tried >= p_max_messages;

      begin
        sys.dbms_aq.dequeue(
          queue_name         => c_queue
        , dequeue_options    => l_dequeue_options
        , message_properties => l_message_properties
        , payload            => l_event
        , msgid              => l_delivery.msg_id
        );
      exception
        when e_no_messages then
          exit message_loop;
      end;

      l_tried                := l_tried + 1;
      l_delivery.attempt     := l_message_properties.attempts + 1;
      l_delivery.enqueued_at := cast(l_message_properties.enqueue_time as timestamp with local time zone);

      begin
        process_event(l_event, l_delivery);

        -- This is the worker's own transaction: the dequeue and everything the workflows did
        -- commit together, or (below) roll back together.
        commit;
        l_handled := l_handled + 1;
      exception
        when others then
          -- Rolling back un-dequeues the message and raises its retry count. Once the count
          -- reaches the queue's max_retries it moves to the exception queue.
          rollback;
          record_failure(l_event, l_delivery, sqlerrm);
          apex_debug.error(
            '%s message %s attempt %s failed: %s %s'
          , c_scope_prefix, rawtohex(l_delivery.msg_id), l_delivery.attempt, sqlerrm
          , sys.dbms_utility.format_error_backtrace
          );
      end;
    end loop message_loop;

    -- The workflows signed this session in as the system user or as an actor. Give the caller its own
    -- identity back: the worker also runs inside a user's session (the Process queue now button).
    adm_context_api.restore_context(l_user, l_role, l_source);

    return l_handled;
  exception
    when others then
      -- for example ORA-25226 while the queue is stopped
      adm_context_api.restore_context(l_user, l_role, l_source);
      raise;
  end process_queue;


  procedure process_queue
  as
    l_handled number;
  begin
    l_handled := process_queue();
  end process_queue;


  procedure on_message (
    context raw
  , reginfo sys.aq$_reg_info
  , descr   sys.aq$_descriptor
  , payload raw
  , payloadl number
  )
  as
    l_handled number;
  begin
    l_handled := process_queue();
  end on_message;


  procedure requeue_failed (
    p_msg_id in raw
  )
  as
    l_dequeue_options    sys.dbms_aq.dequeue_options_t;
    l_enqueue_options    sys.dbms_aq.enqueue_options_t;
    l_message_properties sys.dbms_aq.message_properties_t;
    l_new_properties     sys.dbms_aq.message_properties_t;
    l_event              hkd_event_t;
    l_msg_id             raw(16);
    l_new_msg_id         raw(16);
  begin
    l_dequeue_options.msgid    := p_msg_id;
    l_dequeue_options.wait     := sys.dbms_aq.no_wait;

    sys.dbms_aq.dequeue(
      queue_name         => c_exception_q
    , dequeue_options    => l_dequeue_options
    , message_properties => l_message_properties
    , payload            => l_event
    , msgid              => l_msg_id
    );

    -- a fresh set of properties: the dequeued ones carry the exhausted retry count
    sys.dbms_aq.enqueue(
      queue_name         => c_queue
    , enqueue_options    => l_enqueue_options
    , message_properties => l_new_properties
    , payload            => l_event
    , msgid              => l_new_msg_id
    );
  end requeue_failed;

end hkd_worker_api;
/
