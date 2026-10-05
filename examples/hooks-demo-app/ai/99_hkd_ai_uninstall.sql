-- Removes what install.sql added and gives the demo back its rule-based classifier.
-- Run as the ADM schema owner. Re-runnable.
--
-- It deletes the classifier results, the annotations that the classifier wrote on the documents it
-- classified, and the collections hkd_kb_invoice and hkd_kb_contract of lesson 4. It moves the
-- folders hkd_inbox, hkd_archive and hkd_private of the sample files, with their documents, to the
-- trash. The tags stay, because they are ordinary ADM tags and a person may have set them. The
-- workflow runs in hkd_workflow_runs stay as well. INTAKE_CLASSIFY is enabled again, also when it was
-- switched off before the install.
-- The hooks demo keeps working: 99_hkd_uninstall.sql in ../db removes that as well.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on

-- ---------------------------------------------------------------------------
-- The annotations and the collections of the classifier
-- ---------------------------------------------------------------------------
-- Only the annotations that the classifier wrote, on the documents that it classified:
-- ai.status, ai.model, ai.run_date and kb.<type> for the types of their verdicts. Other ai.* and
-- kb.* annotations, for example your own kb keys for RAG collections, stay.
declare
  c_sql constant varchar2(1000 char) := q'[
    select r.document_id
         , k.annotation_key
      from (select distinct document_id, doc_type from hkd_ai_results) r
      join adm_document_annotations k
        on k.document_id = r.document_id
     where k.annotation_key in ('ai.status', 'ai.model', 'ai.run_date')
        or k.annotation_key = 'kb.' || r.doc_type
  ]';
  l_doc_cur   sys_refcursor;
  l_document  number;
  l_key       varchar2(255 char);
  l_has_table number;

  c_collections_sql constant varchar2(300 char) :=
    q'[select c.collection_name from adm_ai_rag_collections c where c.collection_name in ('hkd_kb_invoice', 'hkd_kb_contract')]';
  c_delete_sql constant varchar2(300 char) :=
    q'[begin adm_ai_rag_api.delete_rag_collection(p_collection_name => :1); end;]';
  l_coll_cur         sys_refcursor;
  l_collection       varchar2(255 char);
  l_has_collections  number;
begin
  adm_context_api.system_login;

  select case when exists (select 1 from user_tables t where t.table_name = 'HKD_AI_RESULTS') then 1 else 0 end
    into l_has_table
    from dual;

  if l_has_table = 1 then
    open l_doc_cur for c_sql; -- @dblinter ignore(g-6010): the statement is a constant of this script
    <<annotation_loop>>
    loop
      fetch l_doc_cur into l_document, l_key; -- @dblinter ignore(g-3140): a weak ref cursor over a constant statement has no row type to anchor to
      exit annotation_loop when l_doc_cur%notfound;
      adm_annotations_api.delete_document_annotation(l_document, l_key);
    end loop annotation_loop;
    close l_doc_cur;
  end if;

  -- The two collections of lesson 4, if you created them. The AI Pack tables are not needed to
  -- uninstall the rest, so this part looks them up only when they exist.
  select case when exists (select 1 from user_tables t where t.table_name = 'ADM_AI_RAG_COLLECTIONS') then 1 else 0 end
    into l_has_collections
    from dual;

  if l_has_collections = 1 then
    open l_coll_cur for c_collections_sql; -- @dblinter ignore(g-6010): the statement is a constant of this script
    <<collection_loop>>
    loop
      fetch l_coll_cur into l_collection; -- @dblinter ignore(g-3140): a weak ref cursor over a constant statement has no row type to anchor to
      exit collection_loop when l_coll_cur%notfound;
      execute immediate c_delete_sql using l_collection;
    end loop collection_loop;
    close l_coll_cur;
  end if;

  commit;
end;
/

-- ---------------------------------------------------------------------------
-- The folders of the sample files
-- ---------------------------------------------------------------------------
begin
  adm_context_api.system_user_login('&hkd_user');

  <<folder_loop>>
  for r in (
    select folder_id
      from adm_folders
     where folder_path in ('/users/' || lower('&hkd_user') || '/hkd_inbox', '/users/' || lower('&hkd_user') || '/hkd_archive', '/users/' || lower('&hkd_user') || '/hkd_private')
       and deleted_flag = 'N'
  ) loop
    adm_folder_api.trash_folder(r.folder_id, '&hkd_user');
  end loop folder_loop;

  commit;
end;
/

delete from hkd_workflows where workflow_code in ('AI_CLASSIFY_UPLOAD', 'AI_CLASSIFY_VERSION', 'AI_RECLASSIFY');
update hkd_workflows set enabled_flag = 'Y' where workflow_code = 'INTAKE_CLASSIFY';
commit;

declare
  procedure drop_if_exists (p_type in varchar2, p_name in varchar2) as
    l_exists number;
    l_ddl    varchar2(200 char);
  begin
    select case when exists (
             select 1
               from user_objects o
              where o.object_type = p_type
                and o.object_name = upper(p_name)
           ) then 1 else 0 end
      into l_exists
      from dual;

    if l_exists = 1 then
      -- The type and the name are literals of this script. dbms_assert checks the name anyway.
      l_ddl := 'drop ' || p_type || ' ' || sys.dbms_assert.simple_sql_name(p_name) || case when p_type = 'TABLE' then ' purge' end; -- @dblinter ignore(g-9501): p_type is one of the literals of this script, never user input
      execute immediate l_ddl;
    end if;
  end drop_if_exists;
begin
  drop_if_exists('PACKAGE', 'hkd_ai_backfill_api');
  drop_if_exists('PACKAGE', 'hkd_ai_api');
  drop_if_exists('VIEW', 'hkd_ai_candidates_v');
  drop_if_exists('VIEW', 'hkd_ai_latest_v');
  drop_if_exists('VIEW', 'hkd_ai_skip_folders_v');
  drop_if_exists('TABLE', 'hkd_ai_labels');
  drop_if_exists('TABLE', 'hkd_ai_results');
  drop_if_exists('TABLE', 'hkd_ai_doc_types');
end;
/

prompt AI workflows removed. INTAKE_CLASSIFY is enabled again.
