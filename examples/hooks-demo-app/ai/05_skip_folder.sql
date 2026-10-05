-- Lesson 5: keep a folder away from the model. Run in SQLcl or SQL*Plus, connected as the ADM
-- schema owner, after lesson 1 and before 05_backfill.sql:
--
--   @05_skip_folder.sql
--
-- It marks a new folder with the annotation ai.skip, uploads a file into it, and shows that the
-- classifier did not send the file to the model. It makes no model call. Run it once: when the
-- folder exists already, it does nothing.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

define hkd_user = ADMIN

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column workflow_code format a20
column status format a8
column summary format a80

-- ---------------------------------------------------------------------------
-- Mark a folder with ai.skip and upload into it
-- ---------------------------------------------------------------------------
declare
  l_home      adm_folders.folder_id%type;
  l_folder_id adm_folders.folder_id%type;
  l_doc_id    adm_documents.document_id%type;
  l_exists    number;
begin
  adm_context_api.system_user_login('&hkd_user');
  l_home      := adm_folder_api.get_folder_id('/users/' || lower('&hkd_user'));

  select case when exists (
           select 1
             from adm_folders
            where folder_path = '/users/' || lower('&hkd_user') || '/hkd_private'
              and deleted_flag = 'N'
         ) then 1 else 0 end
    into l_exists
    from dual;

  if l_exists = 1 then
    sys.dbms_output.put_line('The folder hkd_private exists already, so nothing was loaded.');
    return;
  end if;

  l_folder_id := adm_folder_api.add_folder('hkd_private', l_home);
  adm_annotations_api.add_folder_annotation(l_folder_id, 'ai.skip', 'confidential');

  l_doc_id := adm_document_api.create_document( -- @dblinter ignore(g-2135): create_document is a function, and this script does not need the id
    p_folder_id      => l_folder_id
  , p_document_name  => 'private_letter.pdf'
  , p_file_content   => sys.utl_raw.cast_to_raw('A file that must not leave the database.')
  , p_file_mime_type => 'application/pdf'
  );

  -- The upload hook queued its event in this transaction. The worker sees it at the commit.
  commit;
end;
/
@wait.sql

-- ---------------------------------------------------------------------------
-- Read the outcome
-- ---------------------------------------------------------------------------
select w.workflow_code
     , w.status
     , w.summary
  from hkd_workflow_runs w
 where w.document_id in (select d.document_id from adm_documents d where d.document_name = 'private_letter.pdf' and d.deleted_flag = 'N')
 order by w.run_id;
