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

end hkd_hook_api;
/
