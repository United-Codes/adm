-- Waits until the worker has handled every queued event, at most 150 seconds.
--
--   @wait.sql
--
-- Event handling needs a few seconds for each file: the model call is the slow part.
-- Run this after loading files and before you read the results.
--
-- If it times out, the worker is not running: run ../db/install.sql again, which registers the
-- worker. If the queue is empty and a file still has no result, the event ended in the exception
-- queue, and the script says so.

-- @dblinter ignore(g-5010): a tutorial script prints its results with dbms_output on
-- purpose, so the reader sees them directly in SQLcl.

set serveroutput on
set feedback off

declare
  l_pending  number;
  l_failed   number;
  l_waited   number := 0;
  c_max_wait constant number := 150;
begin
  <<wait_loop>>
  loop
    select count(*)
      into l_pending
      from aq$hkd_event_qt
     where queue     = 'HKD_EVENT_Q'
       and msg_state in ('READY', 'WAIT');

    exit wait_loop when l_pending = 0 or l_waited >= c_max_wait;
    sys.dbms_session.sleep(3);
    l_waited := l_waited + 3;
  end loop wait_loop;

  if l_pending = 0 then
    sys.dbms_output.put_line('The queue is empty (waited ' || l_waited || ' s).');

    -- An event that failed on every attempt is not waiting. It sits in the exception queue.
    select count(*)
      into l_failed
      from aq$hkd_event_qt
     where queue     = 'AQ$_HKD_EVENT_QT_E'
       and msg_state = 'READY';

    if l_failed > 0 then
      sys.dbms_output.put_line('The exception queue holds ' || l_failed || ' events that failed on every attempt. Older failures stay there too.');
      sys.dbms_output.put_line('If a file of yours has no result, read the failed runs: select * from hkd_workflow_runs where status = ''FAILED'' order by run_id desc;');
    end if;
  else
    sys.dbms_output.put_line(l_pending || ' events are still waiting after ' || l_waited || ' s. Run this script again.');
    sys.dbms_output.put_line('If the number does not fall, the worker is not running. Run ../db/install.sql again.');
  end if;
end;
/
