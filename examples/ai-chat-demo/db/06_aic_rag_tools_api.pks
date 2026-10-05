create or replace package aic_rag_tools_api as
  pragma serially_reusable;

  /**
   * Tools for the "Ask questions across your documents" course: semantic (RAG) search over one
   * collection each, as functions an LLM agent can call.
   *
   * The contract of a UC AI tool: one JSON clob in, one JSON clob out, and it NEVER raises. A
   * failure comes back as JSON the model can read, because an exception inside a tool call ends
   * the whole agent run. Every answer has a "status" so the model (and your own tests) can tell
   * the cases apart:
   *
   *   ok           passages found; "passages" holds {document, score, matched_chunks, text}
   *   no_passages  the search ran and found nothing the user may see above the score threshold
   *   no_identity  no ADM user is signed in on this database session, so nothing can be searched
   *   error        anything else (details go to the APEX debug log, not into the answer)
   *
   * "no_passages" and "no_identity" must stay different. ADM filters every passage through the
   * access check of the current user. With no user it returns zero passages without an error, so
   * a missing identity looks exactly like "nothing found" unless the tool checks first.
   *
   * No package state, and the serially_reusable pragma in spec and body: a recompile of a
   * package that holds state ends the session of every long-lived worker with ORA-04061.
   */

  /**
   * Searches the collection aic_contracts.
   * Parameters (JSON): query (required), max_sources (optional, how many documents at most).
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, searched_as, collection and passages or message
   */
  function search_contracts (
    p_parameters in clob
  ) return clob;

  /**
   * Searches the collection aic_policies. Same parameters and answer as search_contracts.
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, searched_as, collection and passages or message
   */
  function search_policies (
    p_parameters in clob
  ) return clob;

  /**
   * The one function behind both tools, public so that a test can pass the knobs a model never
   * sees: p_limit (how many chunks the vector search returns before the access filter) and
   * p_score_threshold.
   *
   * @param p_collection_name Name of the RAG collection
   * @param p_query           The search text
   * @param p_max_sources     Documents at most; null uses the collection default
   * @param p_limit           Vector search top-k; null uses the collection default
   * @param p_score_threshold Minimum score; null uses the collection default
   * @return JSON object, see the package header
   */
  function search (
    p_collection_name in varchar2
  , p_query           in varchar2
  , p_max_sources     in number default null
  , p_limit           in number default null
  , p_score_threshold in number default null
  ) return clob;

end aic_rag_tools_api;
/
