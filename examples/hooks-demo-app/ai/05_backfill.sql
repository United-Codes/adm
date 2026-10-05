-- Lesson 5: classify the documents that were in ADM before the classifier. Run in SQLcl or
-- SQL*Plus, connected as the ADM schema owner, after lesson 4:
--
--   @05_backfill.sql
--
-- It loads the sample set a second time into the folder hkd_archive WITHOUT the upload hook, so
-- these files look like documents from before the classifier existed. Then it classifies them
-- in batches. It sends one model request for each of the twelve files, and three more for the new
-- run at the end, so 15 in all.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

define hkd_user = ADMIN
define hkd_folder_path = /users/admin/hkd_archive

set define on
set verify off
set serveroutput on
set feedback off
set linesize 200
column documents format 999
column verdicts format 999
column document_name format a36
column prompt_tokens format 99999
column completion_tokens format 99999

-- ---------------------------------------------------------------------------
-- Install the backfill package
-- ---------------------------------------------------------------------------
@@04_hkd_ai_backfill_api.pks
@@04_hkd_ai_backfill_api.pkb

-- ---------------------------------------------------------------------------
-- Create documents the hook never saw
-- ---------------------------------------------------------------------------
@@00_load_pdfs.sql ALL hkd_archive NOHOOKS
@@wait.sql

select count(*) as documents
  from adm_documents d
  join adm_folders f
    on f.folder_id = d.folder_id
 where f.folder_path = '&hkd_folder_path'
   and d.deleted_flag = 'N';

select count(*) as classified
  from hkd_ai_results r
  join adm_documents d
    on d.document_id = r.document_id
  join adm_folders f
    on f.folder_id = d.folder_id
 where f.folder_path = '&hkd_folder_path';

-- ---------------------------------------------------------------------------
-- Estimate the tokens of a backfill
-- ---------------------------------------------------------------------------
declare
  l_documents  number;
  l_prompt     number;
  l_completion number;
begin
  hkd_ai_backfill_api.estimate('&hkd_folder_path', l_documents, l_prompt, l_completion);
  sys.dbms_output.put_line('Documents to classify:  ' || l_documents);
  sys.dbms_output.put_line('Estimated input tokens:  ' || l_prompt);
  sys.dbms_output.put_line('Estimated output tokens: ' || l_completion);
end;
/

-- ---------------------------------------------------------------------------
-- Queue the documents in batches
-- ---------------------------------------------------------------------------
-- Each call queues at most 5 documents and none while 40 events wait. The loop waits for the
-- worker between batches and stops when no document is left, or after c_max_batches batches.
-- Run the block again after an interruption: it continues with the documents that have no
-- verdict and no event in the queue.
declare
  l_queued  number := 1;
  l_waiting number;
  l_batches number := 0;
  c_polls   constant pls_integer := 60;
  c_max_batches constant pls_integer := 20;
begin
  adm_context_api.system_login;
  <<batch_loop>>
  loop
    exit batch_loop when l_batches >= c_max_batches;
    l_queued := hkd_ai_backfill_api.enqueue_unclassified(p_batch_size => 5, p_folder_path => '&hkd_folder_path');
    commit; -- @dblinter ignore(g-3320): the commit lets the worker see this batch, and this script is the caller, not a package
    exit batch_loop when l_queued = 0;
    l_batches := l_batches + 1;
    sys.dbms_output.put_line('Batch ' || l_batches || ': queued ' || l_queued || ' documents');

    -- wait until the worker has handled this batch
    <<poll_loop>>
    for i in 1 .. c_polls loop
      select case when exists (
               select 1
                 from aq$hkd_event_qt q
                where q.queue     = 'HKD_EVENT_Q'
                  and q.msg_state in ('READY', 'WAIT')
             ) then 1 else 0 end
        into l_waiting
        from dual;

      exit poll_loop when l_waiting = 0;
      sys.dbms_session.sleep(3);
    end loop poll_loop;
  end loop batch_loop;

  if l_queued = 0 then
    sys.dbms_output.put_line('Nothing left to classify.');
  else
    sys.dbms_output.put_line('Stopped after ' || c_max_batches || ' batches. Run the block again to continue.');
  end if;
end;
/

-- ---------------------------------------------------------------------------
-- Compare the estimate with the tokens used
-- ---------------------------------------------------------------------------
select count(*) as documents
     , sum(r.prompt_tokens) as prompt_tokens
     , sum(r.completion_tokens) as completion_tokens
  from hkd_ai_results r
  join adm_documents d
    on d.document_id = r.document_id
  join adm_folders f
    on f.folder_id = d.folder_id
 where f.folder_path = '&hkd_folder_path'
   and r.status != 'FAILED';

-- ---------------------------------------------------------------------------
-- Classify again after a change
-- ---------------------------------------------------------------------------
-- After you reword a type description, queue the documents whose newest verdict is older than a
-- date. Take the date once for the whole backlog: a verdict from a run after that date is not
-- older than it, so every call continues with the next documents. This example queues only 3.
declare
  l_before timestamp with local time zone := systimestamp;
  l_queued number;
begin
  adm_context_api.system_login;
  l_queued := hkd_ai_backfill_api.enqueue_outdated(
                p_before      => l_before
              , p_folder_path => '&hkd_folder_path'
              , p_batch_size  => 3);
  commit; -- @dblinter ignore(g-3320): the commit lets the worker see the events, and this script is the caller, not a package
  sys.dbms_output.put_line('Queued ' || l_queued || ' documents for a new run');
end;
/
@@wait.sql

-- The three documents now have two verdicts each.
select d.document_name
     , count(*) as verdicts
  from hkd_ai_results r
  join adm_documents d
    on d.document_id = r.document_id
  join adm_folders f
    on f.folder_id = d.folder_id
 where f.folder_path = '&hkd_folder_path'
 group by d.document_name
having count(*) > 1
 order by d.document_name;
