create or replace package aic_app_tools_api as
  pragma serially_reusable;

  /**
   * Lesson 7: the search tools of an agent in the APPLICATION schema (AIC_APP), not in the ADM schema.
   * They search through the synonym aic_rag_bridge_api, which points at the bridge package in the ADM
   * schema. That package is the only ADM object this schema may call.
   *
   * The contract of lesson 2: one JSON clob in, one JSON clob out, never raise. Every answer has a
   * "status":
   *
   *   ok           passages found; "passages" holds {document, score, matched_chunks, text}
   *   no_passages  the search ran and found nothing above the score threshold
   *   error        anything else. A collection name that does not exist comes back with the
   *                message of the bridge, which lists the collections that exist. Other details
   *                go to the APEX debug log, not into the answer.
   *
   * There is no "no_identity" here: the session of this schema needs no ADM user. The bridge
   * searches as its own fixed ADM user, or, for the *_as_app_user functions, as the signed-in APEX
   * user. "searched_as" names the ADM user of the search.
   *
   * One tool per collection, so that the model picks the collection from the tool descriptions and
   * the answer can say which collection a passage came from.
   */

  /**
   * Searches the collection aic_contracts. Parameters (JSON): query (required).
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, collection, searched_as and passages or message
   */
  function search_contracts (
    p_parameters in clob
  ) return clob;

  /**
   * Searches the collection aic_policies. Parameters (JSON): query (required).
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, collection, searched_as and passages or message
   */
  function search_policies (
    p_parameters in clob
  ) return clob;

  /**
   * Searches the collection aic_contracts as the signed-in APEX user, through
   * aic_rag_bridge_api.search_passages_for_user. Parameters (JSON): query (required).
   * Not registered as a tool by 27_aic_app_register.sql. Lesson 7 shows it in the section about a
   * per-user identity.
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, collection, searched_as and passages or message
   */
  function search_contracts_as_app_user (
    p_parameters in clob
  ) return clob;

  /**
   * Searches the collection aic_policies as the signed-in APEX user. See
   * search_contracts_as_app_user.
   *
   * @param p_parameters JSON object with the parameters
   * @return JSON object with status, collection, searched_as and passages or message
   */
  function search_policies_as_app_user (
    p_parameters in clob
  ) return clob;

  /**
   * The function behind the two tools of the fixed identity, public so that a script can call it
   * with any name.
   *
   * @param p_collection_name Name of the RAG collection
   * @param p_query           The search text
   * @return JSON object, see the package header
   */
  function search (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return clob;

  /**
   * The function behind the two per-user tools. It reads the APEX user of the session with
   * sys_context('APEX$SESSION', 'APP_USER') and passes it to the bridge. Without a signed-in user
   * it returns the status error and does not call the bridge.
   *
   * @param p_collection_name Name of the RAG collection
   * @param p_query           The search text
   * @return JSON object, see the package header
   */
  function search_as_app_user (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return clob;

end aic_app_tools_api;
/
