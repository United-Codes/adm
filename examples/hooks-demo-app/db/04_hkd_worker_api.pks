create or replace package hkd_worker_api as

  /**
   * @package
   * Takes the events hkd_hook_api queued and runs the enabled workflows for each of them.
   *
   * Every message is processed in a transaction of its own: dequeue, run the workflows,
   * commit. That is the contrast to the hook, which runs inside the uploader's transaction:
   *
   *   - A failing workflow cannot fail or slow down an upload - the upload committed long ago.
   *   - A failing message is rolled back, which puts it back on the queue with its retry count
   *     raised. The queue redelivers it after the retry delay, and after the configured number
   *     of attempts moves it to the exception queue instead of retrying forever.
   *   - So workflows have to be safe to run twice. They are: tagging is idempotent, and the
   *     folder blueprint checks what already exists.
   *
   * Two things call process_queue: an AQ notification (on_message) so a message is handled
   * within a moment of the upload committing, and a scheduler job as a safety net, because a
   * message that waits out its retry delay produces no notification of its own.
   */

  /**
   * Handles queued events until the queue is empty. Safe to run from several sessions at the
   * same time: dequeue locks the message it takes.
   *
   * @param p_max_messages Stop after this many messages, null for no limit
   * @return The number of messages that were handled successfully
   */
  function process_queue (
    p_max_messages in number default null
  ) return number;

  /** The same, as a procedure, for the scheduler job. */
  procedure process_queue;

  /**
   * The AQ notification callback, registered in 06_hkd_register_hooks.sql. The signature is
   * fixed by Oracle. The payload is only the notification, so all it does is wake up
   * process_queue.
   */
  procedure on_message (
    context raw
  , reginfo sys.aq$_reg_info
  , descr   sys.aq$_descriptor
  , payload raw
  , payloadl number
  );

  /**
   * Moves a message from the exception queue back to the main queue so it is tried again,
   * for the case where the cause - a bug in a workflow, a missing grant - has been fixed.
   *
   * @param p_msg_id The id of the message in the exception queue
   */
  procedure requeue_failed (
    p_msg_id in raw
  );

end hkd_worker_api;
/
