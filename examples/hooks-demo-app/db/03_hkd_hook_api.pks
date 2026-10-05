create or replace package hkd_hook_api as

  /**
   * @package
   * The PL/SQL the ADM hooks call. Hooks run inside the uploader's transaction, so this
   * package does only two things and both are quick:
   *
   *   1. a synchronous guard that can REFUSE the operation (blocked extension, empty file)
   *   2. an enqueue of one message for hkd_worker_api to pick up afterwards
   *
   * Nothing slow happens here. Classification, duplicate detection, notifications and
   * folder provisioning all run later, in the worker's own transaction.
   *
   * Registered by 06_hkd_register_hooks.sql as
   *
   *     hkd_hook_api.after_new_file_upload(
   *       p_document_id => :p_document_id
   *     , p_version_id  => :p_version_id
   *     );
   */

  /**
   * The generation of the event the worker is handling now, and 0 outside the worker. An event
   * that a person caused is generation 1, an event that a workflow caused is generation 2, and
   * so on. The worker sets it while a workflow runs and enqueue_event adds one, so a workflow
   * whose work starts new events that start more events ends at a limit instead of running
   * forever. The count has to travel inside the message, because every event is handled in a
   * transaction of its own.
   *
   * @param p_generation The generation of the event that is about to run, or 0 when the worker is done
   */
  procedure set_generation (
    p_generation in number
  );

  /** The hook for AFTER_NEW_FILE_UPLOAD. Guards the file, then queues the event. */
  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  );

  /** The hook for AFTER_NEW_FILE_VERSION. Guards the version, then queues the event. */
  procedure after_new_file_version (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  );

  /** The hook for AFTER_NEW_FOLDER_CREATION. Only queues the event. */
  procedure after_new_folder_creation (
    p_folder_id in adm_folders.folder_id%type
  );

  /**
   * Queues one event for the worker. The three hooks use it, and so can code of your own that
   * wants a workflow to run for a document without a new upload: register a workflow whose
   * hook_key is the key you pass here.
   *
   * @param p_hook_key    The event name, matched against hkd_workflows.hook_key
   * @param p_document_id The document the event is about, if any
   * @param p_version_id  The version the event is about, if any
   * @param p_folder_id   The folder the event is about, if any
   */
  procedure enqueue_event (
    p_hook_key    in varchar2
  , p_document_id in number default null
  , p_version_id  in number default null
  , p_folder_id   in number default null
  );

end hkd_hook_api;
/
