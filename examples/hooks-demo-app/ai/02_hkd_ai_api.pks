create or replace package hkd_ai_api as

  -- The package keeps nothing between calls. That is what lets you recompile it while the
  -- worker's session is alive: a package that holds state raises ORA-04061 in a session that
  -- loaded the older version.
  pragma serially_reusable;

  /**
   * @package
   * Classifies uploaded PDFs and images with a language model and turns the answer into ADM
   * tags and annotations.
   *
   * The package plugs into the hooks demo worker as a workflow handler: a row in
   * hkd_workflows names classify_event, and the worker calls it for every queued event of
   * that row's hook. It needs the AI Pack (UC AI) in the same schema.
   *
   * What one run writes for a document the model could read:
   *
   *   - a hkd_ai_results row with the verdict, the model and the tokens used
   *   - the tag category=<type>, unless a person set that tag
   *   - the annotations ai.status, ai.model and ai.run_date
   *   - for a type that releases automatically: the annotation kb.<type>. That annotation is
   *     what a RAG collection that selects files by annotation key picks up. A type that needs
   *     review gets the tag needs-review instead, and no kb annotation until a person accepts it.
   */

  -- Where the model is called. Change these three to use another provider or model.
  c_provider   constant varchar2(30 char)  := 'openai';
  c_model      constant varchar2(100 char) := 'gpt-6.1-sol';
  c_credential constant varchar2(100 char) := 'OPENAI';

  /**
   * The workflow handler the worker calls. Matches the signature hkd_workflows.handler expects.
   * Classifies the document of the event and reports an outcome the worker records.
   *
   * @param p_event     The queued event; document_id and, for a version event, version_id
   * @param po_status   OK, FLAGGED (needs a person), SKIPPED or FAILED
   * @param po_summary  One line for hkd_workflow_runs
   */
  procedure classify_event (
    p_event      in  hkd_event_t
  , po_status    out varchar2
  , po_summary   out varchar2
  );

  /**
   * Classifies one document now, in the caller's transaction and with the caller's ADM context.
   * The handler uses it; call it directly to try a document or to measure a prompt.
   *
   * @param p_document_id The document to classify
   * @param p_version_id  The version to read, null for the latest
   * @param p_hardened    False sends the plain prompt without the rule about text inside documents
   * @param p_model       The model to ask, null for c_model
   * @return The hkd_ai_results.result_id of the verdict, null if the document was skipped
   */
  function classify_document (
    p_document_id in number
  , p_version_id  in number default null
  , p_hardened    in boolean default true
  , p_model       in varchar2 default null
  ) return number;

  /**
   * The system prompt: the document types from hkd_ai_doc_types, and optionally the rule that
   * text inside a document is data and never an instruction.
   *
   * @param p_hardened False leaves the rule out
   */
  function get_system_prompt (
    p_hardened in boolean default true
  ) return clob;

  /** The JSON schema of the answer: a doc_type from hkd_ai_doc_types and a reason. */
  function get_response_schema return json_object_t;

  /**
   * Queues a document for classification again, for example after a prompt change.
   * The worker runs it like an upload, but only the AI workflow reacts to it.
   *
   * @param p_document_id The document to classify again
   */
  procedure reclassify (
    p_document_id in number
  );

  /**
   * A person confirms the verdict of a result. An accepted verdict takes effect like a released
   * one: the category tag, the kb annotation, and no needs-review tag.
   *
   * @param p_result_id The result to accept
   * @param p_doc_type  The type to use instead of the model's, null to accept the model's
   */
  procedure accept (
    p_result_id in number
  , p_doc_type  in varchar2 default null
  );

  /**
   * Takes a release back: removes the kb annotation and marks the verdict revoked.
   * The category tag stays, and the document waits for review again.
   *
   * @param p_document_id The document whose latest verdict to revoke
   */
  procedure revoke_release (
    p_document_id in number
  );

end hkd_ai_api;
/
