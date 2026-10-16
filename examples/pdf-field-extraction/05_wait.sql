-- Lesson 5: waits until the AI queue job has extracted every document of the inbox, at most
-- 12 minutes. The job ADM_AI_RAG_QUEUE_JOB runs every five minutes. Calls no model itself.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

@@settings.sql

set define on
set verify off
set feedback off
set serveroutput on

declare
  l_open    pls_integer;
  l_started date := sysdate;
begin
  adm_context_api.system_user_login('&pfx_user');
  <<wait_loop>>
  loop
    -- open: an inbox document without a result for its latest version
    select count(*)
      into l_open
      from adm_my_documents_v d
     where d.folder_path = '&pfx_home/pfx_inbox'
       and not exists (
             select 1
               from adm_my_form_extractions_v x
              where x.profile_name = 'pfx_supplier_forms'
                and x.document_id  = d.document_id
                and x.version_id   = d.latest_version_id
           );
    exit wait_loop when l_open = 0 or sysdate > l_started + 12 / 1440;
    sys.dbms_session.sleep(10);
  end loop wait_loop;

  if l_open = 0 then
    sys.dbms_output.put_line('all inbox documents extracted after ' || round((sysdate - l_started) * 86400) || ' s');
  else
    sys.dbms_output.put_line(l_open || ' document(s) still open after 12 minutes. Is ADM_AI_RAG_QUEUE_JOB enabled? '
      || 'See user_scheduler_jobs, and adm_job_logs with the job id process_form_extractions.');
  end if;
end;
/
