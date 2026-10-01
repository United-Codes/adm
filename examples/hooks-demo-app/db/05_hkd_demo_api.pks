create or replace package hkd_demo_api as

  /**
   * @package
   * Everything the Hooks Demo APEX application calls. Kept apart from the hook and worker
   * packages on purpose: those two are the pattern the demo is about, this one is the glue
   * that lets a browser drive it.
   *
   * Like ADM's own packages it never commits - the APEX page process owns the transaction.
   * The exceptions are the queue operations, which are their own transactions by nature.
   */

  /**
   * Tells ADM who the APEX user is. The app runs it as application initialization code on
   * every request; the adm_my_*_v views and every ADM API see nothing without it.
   */
  procedure establish_context;

  /**
   * Stores an uploaded file in ADM: a new document, or - when the folder already holds a
   * document of that name - a new version of it. That choice is what lets one page demo both
   * AFTER_NEW_FILE_UPLOAD and AFTER_NEW_FILE_VERSION.
   *
   * The merge window is bypassed, so a quick second upload really does create a version.
   * ADM ignores a re-upload whose content equals the latest version, which creates nothing and
   * fires no hook; po_result says UNCHANGED then.
   *
   * When the guard hook refuses the file, its error (-20701, -20702) reaches the caller as it
   * is, and the application's error handling function shows the message to the user.
   *
   * @param p_folder_id The target folder
   * @param p_temp_file The name of the file in apex_application_temp_files
   * @param po_document_id The document that was created or changed
   * @param po_result CREATED, NEW_VERSION or UNCHANGED
   * @param po_file_name The file name that was stored
   */
  procedure upload_file (
    p_folder_id    in  number
  , p_temp_file    in  varchar2
  , po_document_id out number
  , po_result      out varchar2
  , po_file_name   out varchar2
  );

  /**
   * Creates a folder, which fires AFTER_NEW_FOLDER_CREATION.
   *
   * @return The folder id
   */
  function create_folder (
    p_parent_folder_id in number
  , p_folder_name      in varchar2
  ) return number;

  /** Switches a workflow on or off. A disabled workflow is skipped by the worker. */
  procedure set_workflow_enabled (
    p_workflow_code in varchar2
  , p_enabled       in varchar2
  );

  /** Adds an extension to the list the upload guard refuses. */
  procedure add_blocked_extension (
    p_extension in varchar2
  , p_reason    in varchar2 default null
  );

  procedure remove_blocked_extension (
    p_extension in varchar2
  );

  /** Runs the worker now instead of waiting for the notification or the job. */
  procedure process_now;

  /**
   * HTML for the "How it works" page: the live source of one unit (procedure or function)
   * of a demo package, with the comment block above it, preceded by an explanation.
   * Reading it from user_source means the page can never drift from the code that runs.
   *
   * @param p_package The package, for example hkd_hook_api
   * @param p_unit    The procedure or function name inside the package body
   * @param p_intro   Explanation shown above the code, may contain HTML
   * @return HTML
   */
  function render_source (
    p_package in varchar2
  , p_unit    in varchar2
  , p_intro   in varchar2 default null
  ) return clob;

  /** HTML: the PL/SQL snippet each ADM hook currently executes, straight from adm_hooks. */
  function render_registered_hooks return clob;

  /** Deletes the demo's own log tables. Does not touch any document or folder. */
  procedure clear_log;

end hkd_demo_api;
/
