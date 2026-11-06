create or replace package aic_rag_bridge_api as

  /**
   * Lesson 7: the one door through which another schema searches the RAG collections of the course.
   * Install it in the ADM schema, and grant EXECUTE on it, and on nothing else, to the application
   * schema.
   *
   * Why it exists. adm_ai_rag_api.prepare_sources checks every chunk against the ADM user of the
   * session (the ADM context). A session of another application has no ADM user, so prepare_sources
   * returns no rows and no error. The application schema must not get EXECUTE on adm_context_api
   * instead: with it, any code in that schema can log in as any ADM user, administrators included.
   *
   * So the identity is set here, in the ADM schema. Two functions, two trust models:
   *   - search_passages searches as the FIXED user c_service_user. The caller cannot choose
   *     another one. Every user of the other application gets the passages that this one ADM user
   *     may see, no more and no less.
   *   - search_passages_for_user searches as the ADM user whose name the caller passes. The ADM
   *     schema cannot check that name: it trusts every line of code in the application schema to
   *     pass the name of the signed-in user. It refuses unknown and inactive users, users with the
   *     role ADMIN, and users outside c_allowed_groups. The grant on this package covers both
   *     functions. If the other schema needs only the fixed identity, delete this function from
   *     your copy.
   *
   * Both hold the identity for one retrieval only. The body reads all rows, puts the ADM context of
   * the caller back on every path out (also after an error), and only then pipes the rows. A caller
   * that stops fetching early cannot leave the session as the bridge user. If an identity has the
   * role ADMIN when the search starts, the bridge refuses to search.
   *
   * Each call logs in with adm_context_api.system_user_login. With the ADM setting
   * AUDIT_SESSION_EVENTS = Y, that writes one audit row per search. The login also resets the read
   * audit state of the session (adm_audit_api.reset_read_state), so a document that the caller
   * reads again after a search is audited again. A session that holds an embed token loses it:
   * restore_context puts back the user, the role and the access source only.
   *
   * The package holds no state. It cannot be serially_reusable, because SQL calls its functions.
   */

  -- The ADM user that search_passages runs as. 24_aic_bridge_setup.sql creates it: role VIEWER,
  -- member of the group AIC_LEGAL only. It sees the five contracts and the four policies that are
  -- shared with that group, and not the salary bands.
  c_service_user      constant varchar2(30 char) := 'AIC_SERVICE';

  -- Only collections whose name starts with this text can be searched through the bridge. This is
  -- a naming convention, not a security boundary: any ADM administrator can create a collection
  -- with this prefix. What a search returns is limited by the rights of the ADM user it runs as.
  c_collection_prefix constant varchar2(30 char) := 'aic_';

  -- search_passages_for_user searches only as a member of one of these ADM groups.
  c_allowed_groups    constant apex_t_varchar2 := apex_t_varchar2('AIC_LEGAL', 'AIC_HR');

  -- Errors, in the range -20700 .. -20999 that ADM leaves for customer code. The c_msg_* texts
  -- are apex_string.format templates (%0, %1) for adm_error.raise_error. Catch them by name:
  --   exception when aic_rag_bridge_api.e_user_refused then ...

  -- The collection name does not start with c_collection_prefix.
  c_err_collection_refused   constant number := -20750;
  c_msg_collection_refused   constant varchar2(500 char) := 'The search bridge only searches collections whose name starts with "%0". "%1" is not one of them.';
  e_collection_refused       exception;
  pragma exception_init(e_collection_refused, -20750);

  -- No collection of that name exists. The message lists the names that the bridge can search.
  c_err_collection_not_found constant number := -20751;
  c_msg_collection_not_found constant varchar2(500 char) := 'No RAG collection is named "%0". Collections that the search bridge can search: %1.';
  e_collection_not_found     exception;
  pragma exception_init(e_collection_not_found, -20751);

  -- The bridge does not search as this ADM user: unknown, inactive, ADMIN, or outside the groups.
  c_err_user_refused         constant number := -20752;
  c_msg_user_refused         constant varchar2(500 char) := 'The search bridge does not search as "%0": %1.';
  e_user_refused             exception;
  pragma exception_init(e_user_refused, -20752);

  type r_passage_type is record (
    document_name  varchar2(4000 char)
  , score          number
  , matched_chunks number
  , passage_text   clob
  );

  type t_passages is table of r_passage_type;

  /**
   * Searches one RAG collection as c_service_user. The stored search settings of the collection
   * apply (score threshold, maximum sources, surrounding chunks).
   *
   * @param p_collection_name Name of the collection; must start with c_collection_prefix
   * @param p_query           The search text
   * @return The passages, best score first; no rows when nothing matched
   */
  function search_passages (
    p_collection_name in varchar2
  , p_query           in varchar2
  ) return t_passages pipelined;

  /**
   * Searches one RAG collection as the ADM user p_username, with the rights of that user.
   *
   * The ADM schema believes the name. Pass only the name of the user that your application has
   * authenticated, for example the APEX user of the session, never a name from a request or from
   * a model. Refused with e_user_refused: a name that is not an active ADM user, a user with the
   * role ADMIN, and a user who is in none of c_allowed_groups.
   *
   * @param p_username        The ADM user name to search as
   * @param p_collection_name Name of the collection; must start with c_collection_prefix
   * @param p_query           The search text
   * @return The passages, best score first; no rows when nothing matched
   */
  function search_passages_for_user (
    p_username        in varchar2
  , p_collection_name in varchar2
  , p_query           in varchar2
  ) return t_passages pipelined;

end aic_rag_bridge_api;
/
