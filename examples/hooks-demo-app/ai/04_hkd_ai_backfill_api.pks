create or replace package hkd_ai_backfill_api as

  pragma serially_reusable;

  /**
   * @package
   * Classifies the documents that were in ADM before the AI workflows existed, in batches.
   *
   * The upload hook only sees new files. This package finds the documents the classifier has
   * never looked at, estimates what a run costs from the runs so far, and queues them in
   * batches so the provider is not flooded. It queues the same AI_RECLASSIFY event that
   * hkd_ai_api.reclassify queues, so the worker handles them like any other event.
   */

  /**
   * Counts the documents a backfill would classify and estimates the tokens it needs.
   * The estimate is the mean of all earlier verdicts times the number of documents: a scanned
   * file with many pages uses more, a one-page text file less. Before the first verdict there is no
   * mean, and the estimate is 0 tokens. A document with a FAILED verdict counts as classified.
   * The count covers readable files (PDFs and images up to 20 MB) outside folders marked ai.skip,
   * and leaves out documents that have an event in the queue.
   *
   * @param p_folder_path  Only documents in this folder and below, null for all of ADM
   * @param po_documents   The number of documents with no classification yet
   * @param po_prompt_tokens      Estimated input tokens for all of them
   * @param po_completion_tokens  Estimated output tokens for all of them
   */
  procedure estimate (
    p_folder_path         in  varchar2 default null
  , po_documents          out number
  , po_prompt_tokens      out number
  , po_completion_tokens  out number
  );

  /**
   * Queues the next documents that have no classification. A document leaves the list when it
   * has a verdict or an event in the queue, so a repeated call continues where the last one
   * stopped, and a call while the queue is long queues nothing. A document whose event ended in the
   * exception queue has no verdict and no event in the queue, so it comes back on the list.
   *
   * @param p_batch_size  How many documents to queue at most
   * @param p_folder_path Only documents in this folder and below, null for all of ADM
   * @param p_max_queued  Queue nothing when this many events are waiting already
   * @return The number of documents queued
   */
  function enqueue_unclassified (
    p_batch_size  in number default 20
  , p_folder_path in varchar2 default null
  , p_max_queued  in number default 40
  ) return number;

  /**
   * Queues documents whose latest verdict is older than a date, for example after you changed
   * the type descriptions. A verdict that a person accepted, a release that a person took
   * back, and a FAILED verdict stay. Use reclassify for a document with a FAILED verdict.
   * The accepted and revoked decisions stay for the current version only. Use one fixed date for the whole backlog: a verdict from
   * a run after that date is not older than it, so the next call continues with the next documents.
   *
   * @param p_before      Classify again every document whose latest result is older than this
   * @param p_folder_path Only documents in this folder and below, null for all of ADM
   * @param p_batch_size  How many documents to queue at most
   * @param p_max_queued  Queue nothing when this many events are waiting already
   * @return The number of documents queued
   */
  function enqueue_outdated (
    p_before      in timestamp with local time zone
  , p_folder_path in varchar2 default null
  , p_batch_size  in number default 20
  , p_max_queued  in number default 40
  ) return number;

end hkd_ai_backfill_api;
/
