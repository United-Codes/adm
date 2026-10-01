import re, textwrap
# Regenerates the staged scripts 02_queue.sql .. 06_blueprint_loop.sql of the tutorial from the finished demo
# in ../db. Run it after you change db/03_hkd_hook_api.pkb or db/04_hkd_worker_api.pkb:
#
#   python3 generate_stages.py
#
# Lessons 3 to 5 install the worker with features taken away (no failure handling, no wake-up), and lesson 6
# installs the demo itself, so the last lesson cannot drift from the demo. The scripts written by hand are
# 00_setup.sql, 01_guard.sql and 99_teardown.sql.
import os
ROOT=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..')+os.sep
DB=ROOT+'db/'
OUT=ROOT+'tutorial/'

worker_pkb=open(DB+'04_hkd_worker_api.pkb').read()
worker_pks=open(DB+'04_hkd_worker_api.pks').read()
hook_pkb=open(DB+'03_hkd_hook_api.pkb').read()

# ---------------------------------------------------------------- unit extraction
def unit(src, name, kind=None, nth=0):
    """Return the text of a package-body unit: from its (optional) leading comment block to 'end name;'."""
    pat = re.compile(r'(?m)^  (?:procedure|function) '+re.escape(name)+r'\b')
    ms = list(pat.finditer(src))
    m = ms[nth]
    start = m.start()
    # take the comment block directly above
    lines_before = src[:start].split('\n')
    k = len(lines_before)-1  # index of the (empty) last piece
    j = k-1
    while j >= 0 and re.match(r'^ {2,3}(--|/\*\*| \*|\*/)', lines_before[j]):
        j -= 1
    start = len('\n'.join(lines_before[:j+1]))+1 if j+1 < k else start
    end_m = re.compile(r'(?m)^  end '+re.escape(name)+r';').search(src, m.end())
    return src[start:end_m.end()]

def banner(title):
    return ("  -----------------------------------------------------------------------------------------\n"
            f"  -- {title}\n"
            "  -----------------------------------------------------------------------------------------\n")

# ---------------------------------------------------------------- stage building blocks
u = lambda n, nth=0: unit(worker_pkb, n, nth=nth)

outcome   = u('outcome'); format_size = u('format_size'); act_as_system = u('act_as_system')
classify_document = u('classify_document')
wf_classify_full  = u('wf_intake_classify')
wf_dup            = u('wf_duplicate_scan')
record_run        = u('record_run')
record_failure    = u('record_failure')
process_queue_fn  = u('process_queue', nth=0)
process_queue_proc= unit(worker_pkb, 'process_queue', nth=1)
on_message        = u('on_message')
requeue_failed    = u('requeue_failed')

# the poison block, removed for stage 3
poison = re.search(r"    -- A deliberate failure.*?    end if;\n\n", wf_classify_full, re.S).group(0)
wf_classify_s3 = wf_classify_full.replace(poison, '')

# worker loop without the failure handler (stage 3)
handler = re.search(r"      begin\n        process_event\(l_event, l_delivery\);.*?      end;\n    end loop message_loop;", process_queue_fn, re.S).group(0)
loop_s3 = """      process_event(l_event, l_delivery);

      -- This is the worker's own transaction: the dequeue and everything the workflows did
      -- commit together. Stage 4 adds what happens when a workflow raises.
      commit;
      l_handled := l_handled + 1;
    end loop message_loop;"""
process_queue_s3 = process_queue_fn.replace(handler, loop_s3)

def process_event(cases):
    body = """  /**
   * Runs every enabled workflow registered for the event's hook. An exception from a
   * workflow propagates: the caller rolls the whole message back, so either all workflows
   * of a message are recorded or none are.
   */
  procedure process_event (
    p_event    in hkd_event_t
  , p_delivery in t_delivery
  )
  as
    l_outcome t_outcome;
  begin
    for r_wf in (
      select workflow_code
        from hkd_workflows
       where hook_key     = p_event.hook_key
         and enabled_flag = 'Y'
       order by sort_order
    ) loop
      act_as_system;

      l_outcome := case r_wf.workflow_code
"""+cases+"""
                   end;

      record_run(p_event, p_delivery, r_wf.workflow_code, l_outcome);
    end loop;
  end process_event;"""
    return body

cases_s3 = """                     when 'INTAKE_CLASSIFY' then wf_intake_classify(p_event)
                     when 'DUPLICATE_SCAN'  then wf_duplicate_scan(p_event)"""

def preamble(failures):
    s = """create or replace package body hkd_worker_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_worker_api.';
  c_queue        constant varchar2(30 char) := 'HKD_EVENT_Q';
"""
    if failures:
        s += "  c_exception_q  constant varchar2(30 char) := 'AQ$_HKD_EVENT_QT_E';\n"
    s += "\n  c_large_file_bytes constant number := 10 * 1024 * 1024;\n"
    if failures:
        s += "\n  -- Customer range -20700 .. -20999\n  c_err_simulated_failure constant number := -20720;\n"
    s += """
  e_no_messages exception;
  pragma exception_init(e_no_messages, -25228);

  -- What a workflow reports back. The worker turns it into a hkd_workflow_runs row.
  type t_outcome is record (
    status  hkd_workflow_runs.status%type
  , summary hkd_workflow_runs.summary%type
  );

  -- What the worker knows about the message it is working on.
  type t_delivery is record (
    msg_id      raw(16)
  , attempt     number
  , enqueued_at timestamp with local time zone
  );

"""
    return s

def spec(failures, wake):
    s = """create or replace package hkd_worker_api as

  /**
   * @package
   * Takes the events hkd_hook_api queued and runs the enabled workflows for each of them, one
   * transaction for each message.
   */

  /**
   * Handles queued events until the queue is empty.
   *
   * @param p_max_messages Stop after this many messages, null for no limit
   * @return The number of messages that were handled successfully
   */
  function process_queue (
    p_max_messages in number default null
  ) return number;

  /** The same, as a procedure, for the scheduler job. */
  procedure process_queue;
"""
    if failures:
        s += """
  /**
   * Moves a message from the exception queue back to the main queue so it is tried again.
   *
   * @param p_msg_id The id of the message in the exception queue
   */
  procedure requeue_failed (
    p_msg_id in raw
  );
"""
    if wake:
        s += """
  /** The AQ notification callback. The signature is fixed by Oracle. */
  procedure on_message (
    context raw
  , reginfo sys.aq$_reg_info
  , descr   sys.aq$_descriptor
  , payload raw
  , payloadl number
  );
"""
    s += "\nend hkd_worker_api;\n/\n"
    return s

def body(stage):
    failures = stage >= 4
    wake = stage >= 5
    parts = [preamble(failures)]
    parts += [outcome, '\n\n', format_size, '\n\n', act_as_system, '\n\n']
    parts += [banner('Workflow 1: intake classification (AFTER_NEW_FILE_UPLOAD)'), classify_document, '\n\n',
              wf_classify_full if failures else wf_classify_s3, '\n\n']
    parts += [banner('Workflow 2: duplicate and integrity scan (AFTER_NEW_FILE_UPLOAD)'), wf_dup, '\n\n']
    parts += [banner('Dispatch'), record_run, '\n\n', process_event(cases_s3), '\n\n']
    if failures:
        parts += [record_failure, '\n\n', process_queue_fn, '\n\n']
    else:
        parts += [process_queue_s3, '\n\n']
    parts += [process_queue_proc, '\n\n']
    if wake:
        parts += [on_message, '\n\n']
    if failures:
        parts += [requeue_failed, '\n\n']
    parts += ["end hkd_worker_api;\n/\n"]
    return ''.join(parts)

# ---------------------------------------------------------------- hook api, stage 2 (guard + enqueue)
hu = lambda n: unit(hook_pkb, n)
def hook_api_stage2():
    s = """create or replace package hkd_hook_api as

  -- Tells the hook the generation of the event the worker is handling, 0 outside the worker.
  procedure set_generation (
    p_generation in number
  );

  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  );

end hkd_hook_api;
/

create or replace package body hkd_hook_api as

  c_scope_prefix constant varchar2(30 char) := 'hkd_hook_api.';

  -- Errors raised by customer code use -20700 .. -20999. ADM never uses that range.
  c_err_blocked_extension constant number := -20701;
  c_err_empty_file        constant number := -20702;
  c_err_generation_limit  constant number := -20703;
  c_max_generation        constant number := 5;

  g_generation            number := 0;

  procedure set_generation (
    p_generation in number
  )
  as
  begin
    g_generation := p_generation;
  end set_generation;


"""
    s += hu('log_rejection')+'\n\n\n'+hu('guard_file')+'\n\n\n'+hu('enqueue_event')+'\n\n\n'
    s += """  procedure after_new_file_upload (
    p_document_id in adm_documents.document_id%type
  , p_version_id  in adm_document_versions.version_id%type
  )
  as
  begin
    guard_file(adm_hooks_api.c_after_new_file_upload, p_document_id, p_version_id);
    enqueue_event(adm_hooks_api.c_after_new_file_upload, p_document_id, p_version_id);
  end after_new_file_upload;

end hkd_hook_api;
/
"""
    return s

# ---------------------------------------------------------------- the naive blueprint (lesson 6)
guard_re = re.compile(r"    -- The recursion guard\..*?    end if;\n\n", re.S)
bp = u('wf_folder_blueprint')
assert guard_re.search(bp)
naive_pkb = worker_pkb.replace(guard_re.search(bp).group(0),
"""    -- NAIVE VERSION, for lesson 6 only: every new folder gets the standard sub folders, whatever its
    -- parent is. Do not keep it: each sub folder fires this hook again, and so on.
""")
assert naive_pkb != worker_pkb

if __name__ == '__main__':
    import sys
    open(OUT+'.stage3_worker.pkb','w').write(body(3))
    open(OUT+'.stage4_worker.pkb','w').write(body(4))
    open(OUT+'.stage5_worker.pkb','w').write(body(5))
    open(OUT+'.stage2_hook.sql','w').write(hook_api_stage2())
    open(OUT+'.naive_worker.pkb','w').write(naive_pkb)
    open(OUT+'.stage3_worker.pks','w').write(spec(False, False))
    open(OUT+'.stage4_worker.pks','w').write(spec(True, False))
    open(OUT+'.stage5_worker.pks','w').write(spec(True, True))
    print('ok')


# ---------------------------------------------------------------- final scripts
tables_sql = open(DB+'01_hkd_tables.sql').read()
def ensure(name):
    m = re.search(r"  ensure_table\('"+name+r"', q'\[.*?\]'\);\n", tables_sql, re.S)
    return m.group(0)

# Lets the blocks that a reader pastes after a script run without the stop-on-error of the script.
END = '\nwhenever sqlerror continue\n'

def write_stage_scripts():
    install_note = "set verify off\nset serveroutput on\nwhenever sqlerror exit failure\n"

    # ---- 02
    queue_sql = open(DB+'02_hkd_queue.sql').read()
    queue_body = queue_sql[queue_sql.index('-- Not "create or replace"'):]
    s = """-- Lesson 2: hand the work to a queue. Run in SQLcl or SQL*Plus, connected as the ADM schema owner,
-- after 01_guard.sql.
--
--   @02_queue.sql
--
-- What it does:
--   1. creates the payload type hkd_event_t, the queue table, the queue HKD_EVENT_Q and opens its
--      exception queue (needs execute on dbms_aqadm)
--   2. creates hkd_visible_messages, a helper that counts the messages other sessions can see
--   3. replaces hkd_hook_api: the hook now guards the file and then puts one message on the queue
--
-- Re-runnable. The hook registration from lesson 1 does not change.

""" + install_note + "\n" + queue_body + """
-- How many messages could another session read right now? The function runs in an autonomous
-- transaction, so it sees only what has been committed. Use it to check that the queue holds a message
-- back until the uploader commits.
create or replace function hkd_visible_messages return number
as
  pragma autonomous_transaction;
  l_count number;
begin
  select count(*)
    into l_count
    from aq$hkd_event_qt
   where queue     = 'HKD_EVENT_Q'
     and msg_state = 'READY';

  return l_count;
end hkd_visible_messages;
/

""" + hook_api_stage2() + "\nshow errors\n"
    open(OUT+'02_queue.sql','w').write(s + END)

    # ---- 03
    s = """-- Lesson 3: run the work in a worker. Run in SQLcl or SQL*Plus, connected as the ADM schema owner,
-- after 02_queue.sql.
--
--   @03_worker.sql
--
-- What it does:
--   1. creates the table hkd_workflow_runs (one row for each workflow that ran) and hkd_workflows
--      (the registry of workflows, with the two this lesson uses)
--   2. creates hkd_worker_api: it takes a message from the queue, runs the workflows for it and
--      commits. Nothing calls it yet: you run it by hand in this lesson.
--
-- Re-runnable. A table that exists is left alone.

""" + install_note + """
declare
  procedure ensure_table (
    p_table_name in varchar2
  , p_ddl        in varchar2
  )
  as
    l_exists number;
  begin
    select count(*)
      into l_exists
      from user_tables
     where table_name = upper(p_table_name);

    if l_exists = 0 then
      execute immediate p_ddl;
    end if;
  end ensure_table;
begin
""" + ensure('HKD_WORKFLOWS') + "\n" + ensure('HKD_WORKFLOW_RUNS') + """end;
/

-- The registry. The worker runs the enabled workflows that belong to the event it received.
merge into hkd_workflows t
using (
  select 'INTAKE_CLASSIFY' as workflow_code
       , 'AFTER_NEW_FILE_UPLOAD' as hook_key
       , 10 as sort_order
       , 'Intake classification' as name
       , 'Classifies a new file and tags the document in ADM with the category.' as description
    from dual
  union all
  select 'DUPLICATE_SCAN'
       , 'AFTER_NEW_FILE_UPLOAD'
       , 20
       , 'Duplicate and integrity scan'
       , 'Compares the checksum of the new file with every other live document.'
    from dual
) s
on (t.workflow_code = s.workflow_code)
when matched then
  update set t.hook_key    = s.hook_key
           , t.sort_order  = s.sort_order
           , t.name        = s.name
           , t.description = s.description
when not matched then
  insert (workflow_code, hook_key, sort_order, name, description)
  values (s.workflow_code, s.hook_key, s.sort_order, s.name, s.description);

""" + spec(False, False) + "\n" + body(3) + "\nshow errors\n"
    open(OUT+'03_worker.sql','w').write(s + END)

    # ---- 04
    s = """-- Lesson 4: handle a workflow that fails. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after 03_worker.sql.
--
--   @04_failures.sql
--
-- What it does: replaces hkd_worker_api with a version that
--   - rolls a failed message back, so the queue delivers it again, and records each failed delivery
--   - can move a message from the exception queue back to the main queue (requeue_failed)
--   - lets a file with "poison" in its name make the classification workflow raise, on purpose
--
-- Re-runnable.

""" + install_note + "\n" + spec(True, False) + "\n" + body(4) + "\nshow errors\n"
    open(OUT+'04_failures.sql','w').write(s + END)

    # ---- 05
    reg = open(DB+'06_hkd_register_hooks.sql').read()
    notif = reg[reg.index('-- The notification.'):reg.index('-- The sweeper.')]
    sweeper = reg[reg.index('-- The sweeper.'):]
    s = """-- Lesson 5: wake the worker. Run in SQLcl or SQL*Plus, connected as the ADM schema owner, after
-- 04_failures.sql.
--
--   @05_wake.sql
--
-- What it does:
--   1. replaces hkd_worker_api with a version that has on_message, the callback of an AQ notification
--   2. registers that notification: Oracle calls the worker as soon as a message is committed
--   3. creates the scheduler job HKD_PROCESS_QUEUE_JOB, which runs the worker every 30 seconds
--
-- The notification needs job_queue_processes greater than 0. The job needs the CREATE JOB privilege.
-- After this script a message is processed within a moment of the upload, without you running the worker.
-- Re-runnable.

""" + install_note + "\n" + spec(True, True) + "\n" + body(5) + "\nshow errors\n\n" + notif + sweeper
    open(OUT+'05_wake.sql','w').write(s + END)

    # ---- 06 loop
    s = """-- Lesson 6: a folder workflow that feeds itself. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after 05_wake.sql.
--
--   @06_blueprint_loop.sql
--
-- What it does: installs the folder part of the finished demo, with ONE change that makes it wrong. The
-- naive worker gives EVERY new folder three sub folders. Each sub folder is a new folder, so its hook
-- fires again. Run 06_blueprint.sql afterwards to replace it with the correct version.
--
-- This script stops the wake-up job and the notification first, so the loop only advances when you run the
-- worker by hand. 06_blueprint.sql starts them again.
--
-- It runs the files of the finished demo from ../db, so keep the examples/hooks-demo-app layout.

set verify off
set serveroutput on
whenever sqlerror exit failure

begin
  for r in (select job_name from user_scheduler_jobs where job_name = 'HKD_PROCESS_QUEUE_JOB') loop
    sys.dbms_scheduler.disable(r.job_name);
  end loop;

  for r in (select location_name from user_subscr_registrations where location_name like '%HKD_WORKER_API.ON_MESSAGE%') loop
    sys.dbms_aq.unregister(
      reg_list => sys.aq$_reg_info_list(
                    sys.aq$_reg_info(user || '.HKD_EVENT_Q', sys.dbms_aq.namespace_aq, r.location_name, hextoraw('FF'))
                  )
    , reg_count => 1
    );
  end loop;
end;
/

@@../db/01_hkd_tables.sql
@@../db/02_hkd_queue.sql
@@../db/03_hkd_hook_api.pks
@@../db/03_hkd_hook_api.pkb
@@../db/04_hkd_worker_api.pks

""" + naive_pkb.rstrip() + """

show errors

-- The folder hook. This registers the three hooks of the finished demo. It also recreates the
-- notification and re-enables nothing: the job stays disabled until 06_blueprint.sql.
@@../db/06_hkd_register_hooks.sql

begin
  for r in (select job_name from user_scheduler_jobs where job_name = 'HKD_PROCESS_QUEUE_JOB') loop
    sys.dbms_scheduler.disable(r.job_name);
  end loop;

  for r in (select location_name from user_subscr_registrations where location_name like '%HKD_WORKER_API.ON_MESSAGE%') loop
    sys.dbms_aq.unregister(
      reg_list => sys.aq$_reg_info_list(
                    sys.aq$_reg_info(user || '.HKD_EVENT_Q', sys.dbms_aq.namespace_aq, r.location_name, hextoraw('FF'))
                  )
    , reg_count => 1
    );
  end loop;
end;
/
"""
    open(OUT+'06_blueprint_loop.sql','w').write(s + END)

    # ---- 06
    s = """-- Lesson 6: the folder blueprint with its guard. Run in SQLcl or SQL*Plus, connected as the ADM schema
-- owner, after 06_blueprint_loop.sql (or straight after 05_wake.sql).
--
--   @06_blueprint.sql
--
-- What it does: installs the finished demo (examples/hooks-demo-app/db) over everything the lessons
-- built. Same object names, so the lessons' packages are replaced, the missing tables are created and
-- the missing hooks are registered. The folder blueprint now only applies to a folder directly
-- inside a folder named Projects. The worker job and the notification are enabled again.
--
-- It does NOT create the APEX application: see the Hooks demo app page for that.

@@../db/install.sql

begin
  for r in (select job_name from user_scheduler_jobs where job_name = 'HKD_PROCESS_QUEUE_JOB') loop
    sys.dbms_scheduler.enable(r.job_name);
  end loop;
end;
/
"""
    open(OUT+'06_blueprint.sql','w').write(s)

write_stage_scripts()
import os
for f in os.listdir(OUT):
    if f.startswith('.stage') or f.startswith('.naive'):
        os.remove(OUT+f)
print('written')
